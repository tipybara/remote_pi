import Foundation
import RemotePiProtocol
import RemotePiSession

/// The production ``SessionActionsService``, backed by `AppModel`.
///
/// Every method is live. `AppModel` gained the four members this file used to
/// ask for — `request(_:to:)`, `post(_:to:)`, `clearTranscript(_:)` and
/// `extensionUIRequests(for:)` — in `AppModel+Requests.swift`.
///
/// ## Idempotency
///
/// Spec 08 §13.9: one id per **intent**, re-used across retries of that
/// intent, never re-minted per attempt. `request(_:to:)` deliberately does not
/// mint ids — it reads the one on the frame — so the mint has to happen here,
/// where the intent starts. Each method below mints exactly once, at the top,
/// and a retry of that user action is a fresh intent and therefore a fresh id.
@MainActor
final class AppModelSessionActions: SessionActionsService {
    private let app: AppModel
    private let cache: ModelCatalogueCache

    init(app: AppModel, cache: ModelCatalogueCache = .shared) {
        self.app = app
        self.cache = cache
    }

    var isConnected: Bool { app.isRelayConnected }

    func facts(for session: SessionKey) -> RoomFacts {
        // `snapshot.room(_:)` returns nil for a room the relay has not
        // announced. Reporting `unknown` rather than an invented default is
        // what lets the Model row show "Choose a model" instead of a name for
        // a session nobody is listening on (spec 08 §13.10).
        guard let meta = app.snapshot.room(session) else { return .unknown }
        return RoomFacts(meta)
    }

    func compact(_ session: SessionKey) async throws {
        try await app.request(.sessionCompact(id: Self.mint("compact")), to: session)
    }

    func newContext(_ session: SessionKey) async throws {
        // `session_new` clears THIS session's context; it does not create one
        // (spec 08 §13.4). The wire name is the misleading half.
        try await app.request(.sessionNew(id: Self.mint("new")), to: session)
    }

    func setModel(_ model: WireModel, for session: SessionKey) async throws {
        try await app.request(
            .modelSet(
                ModelSet(id: Self.mint("model"), provider: model.provider, modelID: model.id)
            ),
            to: session
        )
        // Invalidation path 1: we know `current` moved, so the cached
        // catalogue is stale the moment the Pi accepts.
        cache.invalidate(session)
    }

    func setThinking(_ level: ThinkingLevel, for session: SessionKey) async throws {
        try await app.request(
            .thinkingSet(ThinkingSet(id: Self.mint("thinking"), level: level)),
            to: session
        )
    }

    func listModels(
        for session: SessionKey,
        forceRefresh: Bool
    ) async throws -> ModelCatalogue {
        // Invalidation path 2 runs on every read rather than on a meta
        // subscription: `facts` is already live, so comparing here catches an
        // external switch (another paired device, or `/model` in the TUI)
        // without another stream to own and cancel.
        cache.invalidateIfCurrentDisagrees(with: facts(for: session), for: session)
        if !forceRefresh, let cached = cache.value(for: session) {
            return cached
        }

        let reply = try await app.request(.listModels(id: Self.mint("models")), to: session)
        // A `models_list` is the only success shape. Anything else that
        // correlated is a protocol surprise, not an empty catalogue — saying
        // so beats rendering "no models" for a Pi that answered wrongly.
        guard case .modelsList(let list) = reply else {
            throw ActionFailure("Pi answered \(reply.typeName) instead of a model list.")
        }
        let catalogue = ModelCatalogue(models: list.models, current: list.current)
        cache.store(catalogue, for: session)
        return catalogue
    }

    func clearLocalTranscript(_ session: SessionKey) async {
        await app.clearTranscript(session)
    }

    @discardableResult
    func respondToExtensionUI(
        _ response: ExtensionUIResponse,
        for session: SessionKey
    ) async -> Bool {
        // Fire-and-forget by design: the Pi routes it to the ask bridge and
        // returns nothing to correlate. The Bool is whether the frame left the
        // device, which is the only fast failure signal the modal has.
        await app.post(.extensionUIResponse(response), to: session)
    }

    /// One id per intent. The prefix is for a human reading a relay log; the
    /// UUID is what makes it unique.
    private static func mint(_ prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString.lowercased())"
    }
}

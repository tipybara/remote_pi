import Foundation
import RemotePiProtocol

// ============================================================================
// The seam between the Quick Actions / ask_user UI and the rest of the app.
//
// Everything in `Actions/` that holds behaviour talks to this protocol and to
// nothing else — not to `AppModel`, not to the Kit's actors. Two reasons, and
// only the second one is about tidiness:
//
//  1. `AppModel` cannot dispatch a typed action today. It owns the
//     `SessionCoordinator` privately, its inbox loop hands every
//     `ServerMessage` straight to `ChatIngest`, and there is no pending-request
//     table to resolve `action_ok` / `action_error` / `models_list` against.
//     Building the sheets against a protocol means the UI is finished and
//     tested now, and wiring it later is one file (`AppModelSessionActions`)
//     rather than a rewrite. See that file's header for the exact list.
//
//  2. It makes the models testable without SwiftUI, without a socket and
//     without a simulator.
// ============================================================================

/// A typed action failure with a message fit to show the user.
///
/// Mirrors Dart's `ActionFailure` (`actions_repository.dart:82-90`): the UI
/// renders ``message`` verbatim, so whatever produces one owes the user a
/// sentence, not an enum case name.
struct ActionFailure: Error, Equatable, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    /// The socket is down. Spec 08 §8.11 has no offline *variant* of the
    /// sheet — the rows stay visible and the failure toasts — so this is a
    /// plain failure and not a separate state.
    static let offline = ActionFailure("Not connected — check the link to Pi.")

    /// The action plumbing has not been wired into `AppModel` yet. Reachable
    /// today; delete the moment the four methods listed in
    /// `AppModelSessionActions` exist.
    static let notWired = ActionFailure("Actions are not available in this build yet.")
}

/// The two `room_meta` fields the Quick Actions sheet hydrates from.
///
/// Read live rather than mirrored into the model: the relay is the source of
/// truth for both, an external switch (another paired device, or `/model` in
/// the TUI) arrives as a meta update, and a local copy is one more thing that
/// can go stale. Spec 08 §8.11 (`quick_actions_viewmodel.dart:145-179`).
struct RoomFacts: Equatable, Sendable {
    /// `room_meta.model` — a **display name**, not a `WireModel`. Never key
    /// anything on it.
    var modelName: String?
    /// `room_meta.thinking`, kept as the raw wire string. The relay never
    /// interprets it and a newer Pi may publish a level this build does not
    /// know; forcing it to a known case would silently show the wrong segment.
    var thinkingRaw: String?

    init(modelName: String? = nil, thinkingRaw: String? = nil) {
        self.modelName = modelName
        self.thinkingRaw = thinkingRaw
    }

    init(_ meta: RoomMeta) {
        self.init(modelName: meta.model, thinkingRaw: meta.thinking)
    }

    /// The parsed level, or `nil` when the Pi has not said / said something
    /// this build does not recognise. A `nil` here renders as "no segment
    /// selected", which is honest — it is not the same as `off`.
    var thinking: ThinkingLevel? {
        thinkingRaw.flatMap(ThinkingLevel.init(wire:))
    }

    static let unknown = RoomFacts()
}

/// The reply to `list_models`: the catalogue plus whichever model the Pi
/// reports as active right now. Mirrors Dart's `ModelsCatalogue`.
struct ModelCatalogue: Equatable, Sendable {
    var models: [WireModel]
    /// The Pi's own answer for "current". The picker's check mark compares
    /// **both** `id` and `provider` against this (spec 08 §8.12) — two
    /// providers can and do expose the same model id.
    var current: WireModel?

    init(models: [WireModel] = [], current: WireModel? = nil) {
        self.models = models
        self.current = current
    }

    static let empty = ModelCatalogue()
}

/// Everything the Quick Actions sheet and the `ask_user` modal need from the
/// app, expressed as one narrow port.
///
/// `@MainActor` because every implementation of it reaches `AppModel`, and
/// because the models that call it are `@MainActor` — hopping actors on each
/// button tap would buy nothing and cost an interleaving to reason about.
@MainActor
protocol SessionActionsService: AnyObject {
    /// The app↔relay socket is up. Property of the socket, not of a room:
    /// dispatching into a dead socket is what produces the 25-second spin the
    /// `ask_user` modal's backstop exists to catch.
    var isConnected: Bool { get }

    /// `(model, thinking)` for one room, as the relay last announced it.
    /// Returns ``RoomFacts/unknown`` for a room the relay has not announced —
    /// never synthesise plausible values.
    func facts(for session: SessionKey) -> RoomFacts

    /// `session_compact` — summarize old turns.
    func compact(_ session: SessionKey) async throws

    /// `session_new` — **clears the context of this same session**. It does
    /// not create one (spec 08 §13.4). The wire name is the misleading half;
    /// the method name here is deliberately not.
    func newContext(_ session: SessionKey) async throws

    /// `model_set {provider, model_id}`.
    func setModel(_ model: WireModel, for session: SessionKey) async throws

    /// `thinking_set {level}`.
    func setThinking(_ level: ThinkingLevel, for session: SessionKey) async throws

    /// `list_models`. Cached per session; `forceRefresh` skips the cache.
    func listModels(for session: SessionKey, forceRefresh: Bool) async throws -> ModelCatalogue

    /// Wipe the local mirror of a session's transcript after the Pi acks a
    /// `session_new` (Dart's `chat.clearActiveSession`). The Pi-side history
    /// is already gone at this point; leaving ours on screen would show a
    /// conversation the agent can no longer see.
    func clearLocalTranscript(_ session: SessionKey) async

    /// Send an `extension_ui_response`.
    ///
    /// Returns whether the frame **actually left the device**. There is no
    /// reply to correlate (`ExtensionUIResponse`'s doc comment), so a `false`
    /// here is the only fast signal that a send went nowhere — without it the
    /// modal spins the full 25 s backstop for a failure we already knew about.
    @discardableResult
    func respondToExtensionUI(
        _ response: ExtensionUIResponse,
        for session: SessionKey
    ) async -> Bool
}

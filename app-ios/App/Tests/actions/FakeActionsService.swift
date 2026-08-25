// ============================================================================
// Tests for `App/Sources/Actions`.
//
// The app target has no test bundle (`project.yml` declares one target), and
// `project.yml` / `Package.swift` were not mine to change, so these files do
// not run in CI yet. They are written against `@testable import RemotePi` —
// the app module's own name — so adding an app test bundle that includes this
// directory is all that is needed:
//
//     RemotePiTests:
//       type: bundle.unit-test
//       platform: iOS
//       sources: [App/Tests]
//       dependencies: [target: RemotePi]
//
// Until then they are verified against the six AppModel-free files in
// `Actions/` (`SessionActions`, `QuickActionsModel`, `ModelPickerModel`,
// `ModelCatalogueCache`, `AskForm`, `AskUserModel`) compiled into a throwaway
// SwiftPM target of the same name. That the models take a protocol instead of
// `AppModel` is exactly what makes that possible.
// ============================================================================

import Foundation
import RemotePiProtocol

@testable import RemotePi

/// A recording ``SessionActionsService`` — the whole reason the models take a
/// protocol instead of `AppModel`.
///
/// Every method records the call and returns whatever the test staged, so a
/// test asserts on *what was dispatched* rather than on a mock's expectations.
@MainActor
final class FakeActionsService: SessionActionsService {
    enum Call: Equatable {
        case compact(SessionKey)
        case newContext(SessionKey)
        case setModel(WireModel, SessionKey)
        case setThinking(ThinkingLevel, SessionKey)
        case listModels(SessionKey, forceRefresh: Bool)
        case clearTranscript(SessionKey)
        case respond(ExtensionUIResponse, SessionKey)
    }

    private(set) var calls: [Call] = []

    var isConnected = true
    var facts = RoomFacts.unknown
    var compactFailure: ActionFailure?
    var newContextFailure: ActionFailure?
    var setModelFailure: ActionFailure?
    var setThinkingFailure: ActionFailure?
    var listModelsResult: Result<ModelCatalogue, ActionFailure> = .success(.empty)
    var respondSucceeds = true

    /// When `true`, `compact` parks until ``release()`` is called — the only
    /// way to observe the model *while* an action is in flight.
    var holdsCompact = false
    private var held: CheckedContinuation<Void, Never>?

    func release() {
        held?.resume()
        held = nil
    }

    func facts(for session: SessionKey) -> RoomFacts { facts }

    func compact(_ session: SessionKey) async throws {
        calls.append(.compact(session))
        if holdsCompact {
            await withCheckedContinuation { held = $0 }
        }
        if let compactFailure { throw compactFailure }
    }

    func newContext(_ session: SessionKey) async throws {
        calls.append(.newContext(session))
        if let newContextFailure { throw newContextFailure }
    }

    func setModel(_ model: WireModel, for session: SessionKey) async throws {
        calls.append(.setModel(model, session))
        if let setModelFailure { throw setModelFailure }
    }

    func setThinking(_ level: ThinkingLevel, for session: SessionKey) async throws {
        calls.append(.setThinking(level, session))
        if let setThinkingFailure { throw setThinkingFailure }
    }

    func listModels(
        for session: SessionKey,
        forceRefresh: Bool
    ) async throws -> ModelCatalogue {
        calls.append(.listModels(session, forceRefresh: forceRefresh))
        return try listModelsResult.get()
    }

    func clearLocalTranscript(_ session: SessionKey) async {
        calls.append(.clearTranscript(session))
    }

    @discardableResult
    func respondToExtensionUI(
        _ response: ExtensionUIResponse,
        for session: SessionKey
    ) async -> Bool {
        calls.append(.respond(response, session))
        return respondSucceeds
    }
}

// MARK: - Fixtures

enum Fixture {
    static func peer(_ byte: UInt8) -> PeerID {
        PeerID(rawValue: Data(repeating: byte, count: 32))!
    }

    static func session(_ byte: UInt8 = 1, room: String = "019ffb64-room") -> SessionKey {
        SessionKey(peer: peer(byte), room: RoomID(room))
    }

    static func model(
        _ id: String,
        name: String? = nil,
        provider: String = "anthropic",
        reasoning: Bool = false,
        contextWindow: Int = 0
    ) -> WireModel {
        WireModel(
            id: id,
            name: name ?? id,
            provider: provider,
            reasoning: reasoning,
            contextWindow: contextWindow
        )
    }

    static func option(
        _ value: String,
        label: String? = nil,
        description: String? = nil,
        preview: String? = nil
    ) -> AskOption {
        AskOption(
            value: value,
            label: label ?? value,
            description: description,
            preview: preview
        )
    }

    static func question(
        _ id: String,
        prompt: String = "prompt",
        type: AskQuestionType = .single,
        presentedType: AskQuestionType? = nil,
        required: Bool = false,
        options: [AskOption] = []
    ) -> AskQuestion {
        AskQuestion(
            id: id,
            label: "",
            prompt: prompt,
            type: type,
            required: required,
            presentedType: presentedType,
            options: options
        )
    }

    static func richRequest(
        id: String = "flow-1",
        title: String? = nil,
        questions: [AskQuestion]
    ) -> ExtensionUIRequest {
        ExtensionUIRequest(
            id: id,
            method: .select,
            title: title,
            ask: AskEnrichment(flowID: id, title: nil, questions: questions)
        )
    }

    static func degradedRequest(
        id: String = "flow-1",
        method: ExtensionUIMethod,
        message: String? = nil,
        placeholder: String? = nil,
        prefill: String? = nil,
        options: [String] = []
    ) -> ExtensionUIRequest {
        ExtensionUIRequest(
            id: id,
            method: method,
            message: message,
            placeholder: placeholder,
            prefill: prefill,
            options: options
        )
    }

    static func notify(
        id: String,
        type: ExtensionUINotifyType? = nil,
        message: String? = nil
    ) -> ExtensionUIRequest {
        ExtensionUIRequest(id: id, method: .notify, message: message, notifyType: type)
    }
}

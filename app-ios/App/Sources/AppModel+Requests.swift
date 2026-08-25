import Foundation
import RemotePiProtocol
import RemotePiSession
import RemotePiStore

// ============================================================================
// The request/reply primitive the Actions agent asked for, plus the two live
// chat signals the composer and the transcript need.
//
// `AppModelSessionActions` listed four things `AppModel` had to gain before
// its six `notWired` bodies could become real:
//
//     request(_:to:)              send and await the frame that answers it
//     post(_:to:)                 fire-and-forget, reporting whether it left
//     clearTranscript(_:)         drop a session's rows after `session_new`
//     extensionUIRequests(for:)   surface the frames `ChatIngest` drops
//
// All four are here. The stored state they need (`pendingRequests`,
// `extensionUIFeeds`, `streamingDrafts`) lives in `AppModel.swift`, because a
// Swift extension cannot add stored properties.
// ============================================================================

// MARK: - Correlating a reply to its request

extension ServerMessage {
    /// The id of the client frame this message answers, or `nil` when it is
    /// unsolicited.
    ///
    /// Deliberately narrow. `agent_chunk` / `agent_done` / `agent_message`
    /// also carry an `in_reply_to`, but it points at a **user message id**,
    /// not at a request id — resolving a waiter on one of those would hand
    /// `request(_:to:)` the first token of an answer and call it a reply.
    ///
    /// `error` is included because `list_models` reports a registry failure as
    /// a plain `error` frame rather than an `action_error` (spec 01).
    var replyCorrelationID: String? {
        switch self {
        case .actionOk(let frame): frame.inReplyTo
        case .actionError(let frame): frame.inReplyTo
        case .modelsList(let frame): frame.inReplyTo
        case .error(let frame): frame.inReplyTo
        case .pong(let inReplyTo): inReplyTo
        case .cancelled(let frame): frame.inReplyTo
        case .sessionHistory(let history): history.inReplyTo
        default: nil
        }
    }

    /// The user-facing failure this frame represents, or `nil` if it is a
    /// success. The message is rendered verbatim, so it comes from the Pi
    /// rather than being invented here.
    var actionFailure: ActionFailure? {
        switch self {
        case .actionError(let frame): ActionFailure(frame.error)
        case .error(let frame): ActionFailure(frame.message)
        default: nil
        }
    }
}

// MARK: - The primitive

extension AppModel {
    /// Send `message` to `session` and await the frame that answers it.
    ///
    /// Resolves on `action_ok` / `action_error` / `models_list` / `error`, and
    /// throws ``ActionFailure`` on refusal, disconnect or timeout. The id is
    /// taken from `message` and never re-minted: spec 08 §13.9 wants one id
    /// per *intent*, re-used across retries of that intent, so that a Pi that
    /// saw the first attempt can dedupe the second.
    @discardableResult
    func request(
        _ message: ClientMessage,
        to session: SessionKey,
        timeout: Duration = .seconds(30)
    ) async throws -> ServerMessage {
        guard let coordinator, isRelayConnected else { throw ActionFailure.offline }
        // `requestID` is nil exactly for the frames nothing answers
        // (`extension_ui_response`, `unknown`). Awaiting a reply to one of
        // those is a caller bug, and hanging until the timeout would hide it —
        // `post(_:to:)` is the method for those.
        guard let id = message.requestID else {
            throw ActionFailure("\(message.typeName) is never answered — use post(_:to:).")
        }

        // Register the waiter BEFORE the write. The reply can land on the
        // inbox task between `send` returning and the continuation being
        // stored, and a reply that arrives with no waiter is dropped — which
        // is a hang, not an error.
        let payload = try WireJSON.encode(message)
        await transport?.retarget(peer: session.peer, room: session.room)

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.failPendingRequest(id, with: ActionFailure("Timed out waiting for Pi."))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            // A duplicate id means the caller re-issued an intent whose first
            // attempt is still outstanding. Fail the older waiter rather than
            // overwrite it silently and strand it forever.
            if let stale = pendingRequests.removeValue(forKey: id) {
                stale.resume(throwing: ActionFailure("Superseded by a retry."))
            }
            pendingRequests[id] = continuation
            Task { [weak self] in
                do {
                    try await coordinator.send(payload, to: session)
                } catch {
                    self?.failPendingRequest(
                        id,
                        with: ActionFailure(error.localizedDescription)
                    )
                }
            }
        }
    }

    /// Fire-and-forget. Returns whether the frame actually left the device —
    /// the `ask_user` backstop depends on learning that immediately rather
    /// than spinning out its 25 s timer for a failure we already knew about.
    @discardableResult
    func post(_ message: ClientMessage, to session: SessionKey) async -> Bool {
        guard let coordinator, isRelayConnected else { return false }
        do {
            await transport?.retarget(peer: session.peer, room: session.room)
            try await coordinator.send(WireJSON.encode(message), to: session)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Delete this session's rows and re-emit its stream.
    ///
    /// Called after the Pi acks a `session_new`. By then the Pi-side history
    /// is already gone, so leaving ours on screen would show a conversation
    /// the agent can no longer see.
    func clearTranscript(_ session: SessionKey) async {
        guard let store else { return }
        do {
            try await store.deleteMessages(for: session)
            drafts[session] = nil
            streamingDrafts[session] = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Inbound `extension_ui_request` frames for one session.
    ///
    /// Multiple subscribers are supported and each gets its own continuation,
    /// so the tablet's detail pane and a pushed chat can both be alive during
    /// a transition without one cancelling the other's feed.
    func extensionUIRequests(for session: SessionKey) -> AsyncStream<ExtensionUIRequest> {
        AsyncStream { continuation in
            let id = UUID()
            extensionUIFeeds[session, default: [:]][id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.extensionUIFeeds[session]?[id] = nil
                    if self?.extensionUIFeeds[session]?.isEmpty == true {
                        self?.extensionUIFeeds[session] = nil
                    }
                }
            }
        }
    }

    // MARK: Live chat signals

    /// The turn streaming in this session right now, if any.
    func streamingDraft(for session: SessionKey) -> StreamingDraft? {
        streamingDrafts[session]
    }

    /// The WHOLE turn is in flight — from the echo through `agent_done`, not
    /// just the token-streaming window.
    ///
    /// ORs the relay's per-room `working` flag with this client's own view of
    /// the open turn. Unlike Home, the chat is *allowed* to do that (spec 08
    /// §7.6.1 vs §8.7): the flag is scoped to the open session and is dropped
    /// when the session changes, so it cannot leave a stale dot on a tile.
    func isTurnInFlight(_ session: SessionKey) -> Bool {
        isWorking(session) || streamingDrafts[session] != nil
    }

    /// The Pi's current queue for this session, if it has announced one.
    func queuedState(for session: SessionKey) -> QueuedMessageState? {
        queuedStates[session]
    }

    /// Why the Pi is unreachable for this session, in words fit to show.
    /// `nil` when it is reachable as far as we know.
    func peerOfflineReason(for session: SessionKey) -> String? {
        byeReasons[session]
    }

    /// The `bye` reasons, as sentences rather than wire tokens.
    static func byeCopy(_ reason: ByeReason) -> String {
        switch reason {
        case .peerStop: "Pi stopped this session."
        case .sessionReplaced: "This session was taken over elsewhere."
        case .shutdown: "Pi shut down."
        default:
            // A newer Pi may send a reason this build does not know. Showing
            // the raw token beats claiming to know why.
            reason.rawValue.isEmpty ? "Pi disconnected." : "Pi disconnected: \(reason.rawValue)"
        }
    }

    /// What a Stop button should cancel. Never `nil` while a turn is in
    /// flight: the fallback chain is streaming turn → the tracked reply-to →
    /// the literal `"working"` the Pi accepts as "whatever is running".
    func cancelTarget(for session: SessionKey) -> String? {
        if let inReplyTo = streamingDrafts[session]?.inReplyTo { return inReplyTo }
        if let any = drafts[session]?.keys.sorted().first { return any }
        return isWorking(session) ? "working" : nil
    }

    // MARK: - Called by the inbox loop

    /// Hand `message` to whoever is waiting on the frame it answers.
    func resolvePendingRequest(with message: ServerMessage) {
        guard
            let id = message.replyCorrelationID,
            let continuation = pendingRequests.removeValue(forKey: id)
        else { return }
        if let failure = message.actionFailure {
            continuation.resume(throwing: failure)
        } else {
            continuation.resume(returning: message)
        }
    }

    func failPendingRequest(_ id: String, with error: any Error) {
        pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
    }

    func failAllPendingRequests(_ error: any Error) {
        let waiting = pendingRequests
        pendingRequests.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    /// Feed the `ask_user` modal. These frames are not transcript rows, which
    /// is why `ChatIngest` ignores them.
    func publishExtensionUI(_ message: ServerMessage, for session: SessionKey) {
        guard case .extensionUIRequest(let request) = message else { return }
        guard let feeds = extensionUIFeeds[session] else { return }
        for continuation in feeds.values { continuation.yield(request) }
    }

    /// Keep the streaming bubble's value in step with the turn.
    ///
    /// `ChatIngest` writes each chunk into the store as it arrives, so the
    /// persisted assistant row and this draft describe the same tokens. The
    /// transcript drops the persisted row while a draft with the same
    /// `in_reply_to` is live — that is what stops the answer rendering twice.
    func trackStreaming(_ message: ServerMessage, for session: SessionKey) {
        switch message {
        case .agentChunk(let chunk):
            var draft = streamingDrafts[session] ?? StreamingDraft(inReplyTo: chunk.inReplyTo)
            // A chunk for a different turn replaces the draft rather than
            // appending to it — two turns never interleave in one session, so
            // this is a new answer, not more of the old one.
            if draft.inReplyTo != chunk.inReplyTo {
                draft = StreamingDraft(inReplyTo: chunk.inReplyTo)
            }
            draft.buffer += chunk.delta
            streamingDrafts[session] = draft

        case .agentDone(let done):
            if streamingDrafts[session]?.inReplyTo == done.inReplyTo {
                streamingDrafts[session] = nil
            }

        case .agentMessage(let payload):
            // A whole-message frame supersedes whatever was accumulating.
            if streamingDrafts[session]?.inReplyTo == payload.inReplyTo {
                streamingDrafts[session] = nil
            }

        case .bye(let reason):
            // The Pi is gone: nothing is streaming and nothing will be until
            // it comes back. `ChatIngest` ignores this frame because it is not
            // a transcript row, so this is the only place it is recorded.
            streamingDrafts[session] = nil
            byeReasons[session] = Self.byeCopy(reason)

        case .queuedMessageState(let state):
            // Wholesale replacement — see `QueuedMessages.swift`.
            queuedStates[session] = state

        case .cancelled, .error:
            streamingDrafts[session] = nil

        default:
            break
        }
    }
}

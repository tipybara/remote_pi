import Foundation
import Observation
import RemotePiProtocol

/// The `ask_user` modal's inbox, form state and submit lifecycle
/// (spec 08 §8.13).
///
/// ## One object, not two
///
/// Flutter splits this across the chat view model (routing, `pendingUiRequest`,
/// `pendingUiError`) and the sheet's `State` (the form, the spinner, the 25 s
/// backstop), and pays for it with `didUpdateWidget` (`:55-75`) — a rule that
/// says "stop the spinner when an error *arrives*, but explicitly not when one
/// is *cleared*", because clearing is what the view model does at the start of
/// a retry and stopping there would re-enable the buttons mid-flight and allow
/// a double submit.
///
/// Here both halves are one object, so the transition that trap describes does
/// not exist: ``submit()`` clears the message and raises the spinner in the
/// same statement, and only ``reject(_:)`` and ``backstopElapsed()`` lower it.
/// There is no observer to mis-trigger.
///
/// ## Nothing here closes the modal optimistically
///
/// pi-ask can reject an answer (`invalid_answer`) without emitting
/// `completed`. Closing on send would leave the flow blocked on the desktop
/// with no way back — a dead end. The modal closes on exactly two things: the
/// `completed` dismiss notify, and an outbound cancel.
@MainActor
@Observable
final class AskUserModel {
    /// The open request, or `nil` when no modal should be shown.
    private(set) var form: AskForm?

    /// The rejection message under the buttons. Non-nil keeps the modal open.
    private(set) var errorMessage: String?

    /// `true` between a send and its answer. Buttons disabled, spinner on
    /// Submit.
    private(set) var isSubmitting = false

    /// `true` once the backstop fired: the send is unaccounted for and the
    /// user is offered a retry rather than an endless spinner.
    private(set) var showsAwaitHint = false

    /// How long to wait for a `completed` / rejection before showing the
    /// await hint. Injectable so a test does not have to wait 25 seconds.
    var backstopDelay: Duration = .seconds(25)

    private var backstop: Task<Void, Never>?
    private var service: (any SessionActionsService)?
    private var session: SessionKey?

    init() {}

    func bind(to service: any SessionActionsService, session: SessionKey) {
        if self.session != session {
            // A different session's flow is not this session's business.
            // Dropping it is the same rule as every other chat-scoped sheet
            // (spec 08 §11.2): a modal hovering over the wrong transcript
            // would submit an answer into a flow the user is no longer
            // looking at.
            clear()
        }
        self.service = service
        self.session = session
    }

    /// Cancel the backstop. Call from the presenting view's `onDisappear`.
    func deactivate() {
        backstop?.cancel()
        backstop = nil
    }

    // MARK: - Inbound routing (§8.13, `chat_viewmodel.dart:254-276`)

    /// Route one `extension_ui_request` frame.
    ///
    /// ```
    /// notify + id matches the open request
    ///     notify_type ∈ {warning, error} -> keep the modal, show the message
    ///     otherwise                      -> `completed` dismiss: close it
    /// notify + id matches nothing        -> ignored (stand-alone notice, v1)
    /// anything else                      -> open / replace the modal
    /// ```
    ///
    /// Note the `warning`/`error` test is on the *value*, not on presence:
    /// `ExtensionUIRequest.isDismissNotify` treats only an **absent**
    /// `notify_type` as a dismiss, which would leave an `info` notify for the
    /// open flow doing nothing at all. The Flutter routing dismisses on
    /// `info` too (`:262-268`), and a flow that finished is finished.
    func receive(_ request: ExtensionUIRequest) {
        guard request.method == .notify else {
            open(request)
            return
        }
        guard let current = form?.request, current.id == request.id else {
            // Stand-alone notices have no modal to act on. Rendering them as
            // one would put a blocking sheet in front of a message that needs
            // no answer.
            return
        }
        if request.notifyType == .warning || request.notifyType == .error {
            reject(request.message?.isEmpty == false
                ? request.message!
                : "Answer was not accepted.")
        } else {
            clear()
        }
    }

    /// Open or replace the modal.
    ///
    /// Replacing resets the form. Question ids repeat across flows (`"goal"`
    /// is the canonical example), so carrying selections over would leak the
    /// previous flow's answers into the new one — which is why the Flutter
    /// sheet is keyed `ValueKey(uiRequest.id)`.
    private func open(_ request: ExtensionUIRequest) {
        deactivate()
        form = AskForm(request: request)
        errorMessage = nil
        isSubmitting = false
        showsAwaitHint = false
    }

    /// Close the modal and forget the flow.
    func clear() {
        deactivate()
        form = nil
        errorMessage = nil
        isSubmitting = false
        showsAwaitHint = false
    }

    /// A rejection arrived: stop spinning so the user can edit and retry.
    func reject(_ message: String) {
        deactivate()
        errorMessage = message
        isSubmitting = false
        showsAwaitHint = false
    }

    // MARK: - Form editing

    var canSubmit: Bool { form?.canSubmit ?? false }

    /// Buttons are live only when there is something to send and nothing in
    /// flight.
    var isSubmitEnabled: Bool { canSubmit && !isSubmitting }

    func toggle(_ question: AskQuestion, value: String) {
        guard !isSubmitting else { return }
        form?.toggle(question, value: value)
    }

    func setCustom(_ value: String, for question: AskQuestion) {
        guard !isSubmitting else { return }
        form?.setCustom(value, for: question)
    }

    func setSingleValue(_ value: String?) {
        guard !isSubmitting else { return }
        form?.singleValue = value
    }

    func setText(_ value: String) {
        guard !isSubmitting else { return }
        form?.text = value
    }

    // MARK: - Submit lifecycle

    func submit() async {
        guard let form, form.canSubmit, !isSubmitting else { return }
        await send(form.response())
    }

    /// Cancel the flow. Also what a swipe-to-dismiss and the close button must
    /// call: on Android the Flutter sheet intercepts system back with
    /// `PopScope(canPop: false)` and maps it here, and an iOS dismissal that
    /// merely made the modal disappear would leave pi-ask blocked until its
    /// 10-minute TTL expired.
    func cancel() async {
        guard let form, !isSubmitting else { return }
        let response = form.cancelResponse()
        // A cancel *does* close the modal locally — unlike a submit. There is
        // no acknowledgement to wait for and nothing left to retry, so holding
        // the sheet up would strand the user behind a spinner.
        clear()
        guard let service, let session else { return }
        _ = await service.respondToExtensionUI(response, for: session)
    }

    private func send(_ response: ExtensionUIResponse) async {
        isSubmitting = true
        // Clearing here is safe precisely because the spinner is raised in the
        // same statement — see the type doc for the Flutter trap this avoids.
        errorMessage = nil
        showsAwaitHint = false
        armBackstop()

        guard let service, let session else {
            reject(ActionFailure.notWired.message)
            return
        }
        let sent = await service.respondToExtensionUI(response, for: session)
        if !sent {
            // The frame never left the device. There is no reply to wait for,
            // so failing now beats spinning the full backstop for a failure
            // we already know about (`chat_viewmodel.dart:340-348`).
            reject("Not connected — check the link to Pi and retry.")
        }
    }

    private func armBackstop() {
        deactivate()
        let delay = backstopDelay
        backstop = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.backstopElapsed()
        }
    }

    /// The backstop transition, separated from the timer that drives it so a
    /// test can exercise it without waiting.
    func backstopElapsed() {
        guard isSubmitting else { return }
        isSubmitting = false
        showsAwaitHint = true
    }

    /// The hint under the buttons: a rejection outranks the await hint,
    /// because it says something specific.
    var footerNote: FooterNote? {
        if let errorMessage, !errorMessage.isEmpty { return .error(errorMessage) }
        if showsAwaitHint { return .awaiting("No response from Pi yet — retry or cancel.") }
        return nil
    }

    enum FooterNote: Equatable {
        case error(String)
        case awaiting(String)
    }
}

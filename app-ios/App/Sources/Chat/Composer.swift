import Foundation
import Observation
import RemotePiProtocol
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// ============================================================================
// The composer — spec 08 §8.7 (with §8.8 steering, §8.9 voice, §8.10 images).
//
// All of the behaviour is in ``ComposerModel``, which has no SwiftUI in it and
// is driven entirely through injected seams, so every state below — including
// offline, permission-denied and pick-failed — is reachable in a unit test.
//
// The distinction the spec is emphatic about, restated here because getting it
// wrong is silent:
//
//   * **Steer** = sending while a turn is in flight. It is an ordinary
//     `user_message` with `streaming_behavior: "steer"`, sent NOW. The
//     composer does this whenever ``ComposerGate/isWorking`` is true.
//   * **Queue** = a follow-up parked on the Pi for after the turn. Different
//     frames, different lifecycle, and NOT what the send button does. See
//     `QueuedMessages.swift`.
//
// Sending while working must never block, queue-and-wait, or be disabled. The
// user typing into a running turn is how they redirect the agent.
// ============================================================================

// MARK: - Host seam

/// What the composer needs the app to do. Implemented by the chat screen's
/// model (which owns `AppModel`), faked in tests.
@MainActor
protocol ComposerHost: QueuedMessageSink {
    /// Persist an optimistic pending row, then ship a `user_message`.
    ///
    /// `steer` maps to `streaming_behavior: "steer"`. When it is `false` the
    /// key must be **omitted**, never sent as `null` — older Pi extensions
    /// reject the explicit null (spec §13.11).
    ///
    /// `image` rides inline on this frame as standard base64, and only on this
    /// frame: images never travel on a queued message.
    func composerSend(text: String, image: ComposerImage?, steer: Bool) async

    /// `cancel {target_id}` — stop the turn in flight.
    func composerCancel(targetID: String) async
}

// MARK: - Gate

/// Everything the host knows that decides whether the composer is usable.
///
/// A plain value so the chat screen can hand it down and the model can be
/// driven straight from a test with no chat around it.
struct ComposerGate: Equatable, Sendable {
    /// The chat has finished bootstrapping. There is deliberately no
    /// connecting spinner (§8.1) — a not-ready chat renders normally with a
    /// locked composer.
    var isReady = false
    /// The app↔relay socket is down.
    var isOffline = false
    var pairingRevoked = false
    /// The Pi said `bye`; the string is why.
    var peerOfflineReason: String?
    /// The relay reports the room as not live.
    var presenceOffline = false
    /// The WHOLE turn is in flight — send/echo through `agent_done`, not just
    /// the token-streaming window. This is what turns a send into a steer and
    /// an empty composer into a Stop button.
    var isWorking = false
    /// What to `cancel`. Never `nil` while `isWorking` (§8.7): the host falls
    /// back through streaming → tracked reply-to → the literal `"working"`.
    var cancelTargetID: String?

    init(
        isReady: Bool = false,
        isOffline: Bool = false,
        pairingRevoked: Bool = false,
        peerOfflineReason: String? = nil,
        presenceOffline: Bool = false,
        isWorking: Bool = false,
        cancelTargetID: String? = nil
    ) {
        self.isReady = isReady
        self.isOffline = isOffline
        self.pairingRevoked = pairingRevoked
        self.peerOfflineReason = peerOfflineReason
        self.presenceOffline = presenceOffline
        self.isWorking = isWorking
        self.cancelTargetID = cancelTargetID
    }

    /// `chat_page.dart:436-447`.
    var isDisabled: Bool {
        !isReady || isOffline || pairingRevoked || peerOfflineReason != nil || presenceOffline
    }

    /// Gates ⚙ and 📎. Quick actions need an open channel to dispatch on, so
    /// they are offered only when the field itself is live — a tap that could
    /// only throw inside the sheet is worse than a missing button.
    var actionsEnabled: Bool { !isDisabled }
}

// MARK: - Derived UI decisions

/// What the round button on the right does right now (§8.7).
enum ComposerPrimaryAction: Equatable, Sendable {
    /// Working with an empty field → Stop.
    case cancel
    /// Text typed **or** an image attached → Send.
    case sendText
    /// Otherwise → hold-to-talk.
    case sendAudio

    var symbol: String {
        switch self {
        case .cancel: "stop.fill"
        case .sendText: "paperplane.fill"
        case .sendAudio: "mic.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .cancel: "Stop the current response"
        case .sendText: "Send"
        case .sendAudio: "Hold to talk"
        }
    }
}

/// What a hardware Return should do.
enum ReturnKeyOutcome: Equatable, Sendable {
    /// Not ours — let the field handle it.
    case ignored
    case insertedNewline
    case submit
}

/// A transient message the composer asks its host to show. Modelled as state
/// rather than as a call into a presenter so the tests can assert on it.
struct ComposerToast: Equatable, Identifiable, Sendable {
    enum Action: Equatable, Sendable {
        case none
        /// Deep-link to this app's page in Settings.
        case openSettings
    }

    let id = UUID()
    let message: String
    let action: Action
    let duration: Duration

    static func == (lhs: ComposerToast, rhs: ComposerToast) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Model

@MainActor
@Observable
final class ComposerModel {
    /// The field text. Writable: the view binds a `TextField` to it.
    var draft = ""

    private(set) var gate = ComposerGate()
    private(set) var toast: ComposerToast?

    /// Bumped when the model wants the field focused (pulling a queued message
    /// back for editing). The view watches it rather than owning a
    /// `@FocusState` the model cannot reach.
    private(set) var focusToken = 0

    /// Drives the attach sheet. Owned here so the ⚙/📎 enablement rules and
    /// the sheet's presentation cannot disagree.
    var isAttachSheetPresented = false

    let attachment: AttachmentModel
    let voice: VoiceInputModel
    let queued: QueuedMessagesModel

    private let host: any ComposerHost
    /// How long the press must last before it counts as a hold rather than a
    /// tap. Injected so the gesture state machine is testable without waiting.
    private let holdDelay: Duration
    private var pressTask: Task<Void, Never>?
    private var pressDidHold = false
    private var toastTask: Task<Void, Never>?

    init(
        host: any ComposerHost,
        attachment: AttachmentModel,
        voice: VoiceInputModel,
        queued: QueuedMessagesModel,
        holdDelay: Duration = .milliseconds(280)
    ) {
        self.host = host
        self.attachment = attachment
        self.voice = voice
        self.queued = queued
        self.holdDelay = holdDelay
    }

    /// The wiring the app uses. Kept next to `init` so a screen never has to
    /// remember which three collaborators the composer needs.
    static func live(host: any ComposerHost) -> ComposerModel {
        ComposerModel(
            host: host,
            attachment: AttachmentModel(picker: makeSystemImagePicker()),
            voice: VoiceInputModel(engine: makeSystemSpeechEngine()),
            queued: QueuedMessagesModel(sink: host)
        )
    }

    // MARK: Lifecycle

    /// Connect the one-shot callbacks and read the cached mic permission.
    /// Idempotent — reassigning the closures is free.
    func activate() {
        voice.onTranscript = { [weak self] text in self?.applyTranscript(text) }
        voice.onHint = { [weak self] hint in self?.show(hint) }
        attachment.onHint = { [weak self] hint in self?.show(hint) }
        voice.prepare()
    }

    /// Release the microphone and stop every timer this model started.
    func deactivate() {
        pressTask?.cancel()
        pressTask = nil
        toastTask?.cancel()
        toastTask = nil
        voice.teardown()
    }

    func apply(_ gate: ComposerGate) {
        guard gate != self.gate else { return }
        self.gate = gate
    }

    // MARK: Derived state

    var isDisabled: Bool { gate.isDisabled }

    var hasImage: Bool { attachment.hasImage }

    /// Text typed OR an image attached. An image alone is a valid send — the
    /// caption is optional.
    var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasImage
    }

    var showStrip: Bool { voice.state.showsStrip }

    /// §8.7, in priority order.
    var placeholder: String {
        if isDisabled { return "Offline…" }
        if gate.isWorking { return "Steer current response…" }
        if hasImage { return "Add a caption…" }
        return "Send a message…"
    }

    var primaryAction: ComposerPrimaryAction {
        if gate.isWorking && !hasContent { return .cancel }
        if hasContent { return .sendText }
        return .sendAudio
    }

    /// The mic disappears entirely when no on-device recogniser exists — an
    /// always-failing button is worse than none (§8.7).
    var hidesPrimaryAction: Bool {
        primaryAction == .sendAudio && voice.state.hidesMicButton
    }

    /// ⚙ shows only on an empty, idle, live composer, so it never competes
    /// with the send affordance.
    var showsQuickActions: Bool {
        draft.isEmpty && !hasImage && !isDisabled && !gate.isWorking && !showStrip
    }

    /// 📎 is always visible; this is whether it does anything. Note the
    /// tri-state vision gate: unknown does NOT disable.
    var attachEnabled: Bool {
        !isDisabled && !gate.isWorking && !showStrip && !attachment.attachBlockedByVision
            && !hasImage && !attachment.isPicking
    }

    /// While steering with typed content the primary button is Send, so Stop
    /// needs its own affordance or cancellation becomes unreachable.
    var showsInlineStop: Bool {
        gate.isWorking && hasContent && !isDisabled && !showStrip && gate.cancelTargetID != nil
    }

    // MARK: Actions

    /// Trim, bail on nothing-to-send, clear the field, ship it.
    ///
    /// The image is taken (read **and** cleared) in one step, so a double-tap
    /// cannot send the same attachment twice.
    func submit() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || attachment.hasImage else { return }
        let image = attachment.takeImageForSend()
        draft = ""
        // Steer whenever a turn is in flight. This is a send, not a queue: the
        // frame goes out immediately and the Pi redirects the running turn.
        await host.composerSend(text: text, image: image, steer: gate.isWorking)
    }

    func cancel() async {
        guard let targetID = gate.cancelTargetID else { return }
        await host.composerCancel(targetID: targetID)
    }

    /// Tap on the primary button. Long-press is handled by the mic path below.
    func primaryTapped() async {
        switch primaryAction {
        case .cancel:
            await cancel()
        case .sendText:
            guard !isDisabled else { return }
            await submit()
        case .sendAudio:
            // Handled by the press gesture; a bare tap only ever explains it.
            voice.tapped()
        }
    }

    func openAttachSheet() {
        guard attachEnabled else { return }
        isAttachSheetPresented = true
    }

    func pick(from source: AttachSource) async {
        await attachment.pick(from: source)
    }

    /// Pull an editable queued item back into the field for editing.
    func editQueued(_ item: QueuedMessageItem) async {
        guard let text = await queued.take(item) else { return }
        draft = text
        focusToken &+= 1
    }

    func clearQueued(_ item: QueuedMessageItem) async {
        await queued.clear(id: item.id)
    }

    /// Session switch: nothing typed, attached or queued for one chat may
    /// follow the user into another.
    func resetForSessionChange() {
        draft = ""
        attachment.reset()
        queued.reset()
        toastTask?.cancel()
        toast = nil
        voice.teardown()
    }

    // MARK: Hardware keyboard

    /// Plain Return sends, Shift+Return inserts a newline (§8.7).
    ///
    /// Only hardware keyboards reach this: the software keyboard's Return goes
    /// through the text-input system as a newline and never surfaces as a key
    /// press, which is exactly the behaviour we want on a phone.
    ///
    /// **Known gap vs the Dart:** the Flutter version also ignores Return while
    /// an IME composition is active, because a CJK candidate is *confirmed*
    /// with Return, not sent. SwiftUI exposes no marked-text state at this
    /// deployment target, so that guard cannot be reproduced here. Flagged
    /// rather than faked.
    func handleReturnKey(shiftPressed: Bool) -> ReturnKeyOutcome {
        guard !isDisabled else { return .ignored }
        if shiftPressed {
            insertNewline()
            return .insertedNewline
        }
        return .submit
    }

    /// **Deviation from `_insertNewlineAtCursor`:** the Dart splices at the
    /// caret. `TextField`'s selection binding lands after our iOS 18.0 floor,
    /// so the newline is appended at the end. Revisit when the floor moves.
    func insertNewline() {
        draft.append("\n")
    }

    // MARK: Hold-to-talk gesture

    /// The press went down. Recording starts only once it has lasted
    /// ``holdDelay`` — before that it is still a tap.
    func micPressBegan() {
        pressDidHold = false
        pressTask?.cancel()
        pressTask = Task { [weak self, holdDelay] in
            try? await Task.sleep(for: holdDelay)
            guard let self, !Task.isCancelled else { return }
            self.pressDidHold = true
            await self.voice.beginHold()
        }
    }

    /// `dx` is the horizontal translation from the press origin (negative =
    /// left). The −90pt threshold lives in ``VoiceInputModel``.
    func micPressMoved(dx: Double) {
        guard pressDidHold else { return }
        voice.updateHold(dx: dx)
    }

    func micPressEnded() async {
        pressTask?.cancel()
        pressTask = nil
        let held = pressDidHold
        pressDidHold = false
        if held {
            await voice.endHold()
        } else {
            voice.tapped()
        }
    }

    // MARK: Toasts

    func dismissToast() {
        toastTask?.cancel()
        toastTask = nil
        toast = nil
    }

    private func applyTranscript(_ text: String) {
        guard !text.isEmpty else { return }
        // Replace, never append: the mic is only reachable from an empty
        // field, so there is nothing to merge with — and merging a dictation
        // into a half-typed line is how you get sentences nobody wrote.
        draft = text
        focusToken &+= 1
    }

    private func show(_ hint: VoiceHint) {
        switch hint {
        case .holdToTalk:
            present(ComposerToast(message: "Hold the mic to talk", action: .none, duration: .seconds(2)))
        case .permissionDenied:
            present(
                ComposerToast(
                    message: "Microphone access is off — enable it in Settings to dictate.",
                    action: .openSettings,
                    duration: .seconds(5)
                )
            )
        }
    }

    private func show(_ hint: AttachHint) {
        switch hint {
        case .cameraPermissionDenied:
            present(
                ComposerToast(
                    message: "Camera access is off — enable it in Settings to attach a photo.",
                    action: .openSettings,
                    duration: .seconds(5)
                )
            )
        case .pickFailed:
            present(
                ComposerToast(
                    message: "Couldn't attach that image.",
                    action: .none,
                    duration: .seconds(3)
                )
            )
        }
    }

    private func present(_ next: ComposerToast) {
        toastTask?.cancel()
        toast = next
        toastTask = Task { [weak self, duration = next.duration] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled else { return }
            guard self.toast?.id == next.id else { return }
            self.toast = nil
        }
    }
}

// MARK: - View

/// The bottom-anchored composer (§8.7).
///
/// Layout, top to bottom: the attachment preview, one card per queued
/// follow-up, then the row. The recording strip covers the row as a
/// non-interactive overlay so the in-flight long-press keeps feeding the mic
/// button underneath — the gesture must survive the row→strip swap.
struct ComposerBar: View {
    @Bindable var model: ComposerModel
    let gate: ComposerGate
    var onOpenQuickActions: (() -> Void)?

    @Environment(\.theme) private var theme
    @Environment(SessionSelection.self) private var selection: SessionSelection?
    @Environment(\.openURL) private var openURL
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let toast = model.toast {
                toastView(toast)
            }
            ZStack {
                VStack(alignment: .leading, spacing: 0) {
                    if model.hasImage {
                        AttachmentPreview(image: model.attachment.preview) {
                            model.attachment.removeImage()
                        }
                    }
                    ForEach(model.queued.items) { item in
                        QueuedMessagePreview(
                            item: item,
                            onEdit: { Task { await model.editQueued(item) } },
                            onClear: { Task { await model.clearQueued(item) } }
                        )
                    }
                    row
                }
                if model.showStrip {
                    strip
                }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 22, trailing: 14))
        .background(theme.colors.bg)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.colors.border)
                .frame(height: AppMetrics.hairline)
        }
        .task(id: gate) { model.apply(gate) }
        .task { model.activate() }
        .onDisappear { model.deactivate() }
        .onChange(of: model.focusToken) { _, _ in fieldFocused = true }
        .sheet(isPresented: $model.isAttachSheetPresented) { attachSheet }
    }

    // MARK: Row

    private var row: some View {
        HStack(alignment: .bottom, spacing: 0) {
            quickActionsButton
            attachButton
            Spacer().frame(width: 10)
            field
            Spacer().frame(width: 10)
            if !model.hidesPrimaryAction {
                primaryButton
            }
            if model.showsInlineStop {
                Spacer().frame(width: 8)
                inlineStop
            }
        }
    }

    private var field: some View {
        TextField(
            "",
            text: $model.draft,
            prompt: Text(model.placeholder).foregroundStyle(theme.colors.muted),
            axis: .vertical
        )
        .font(theme.type.mono(13))
        .foregroundStyle(theme.colors.text)
        .tint(theme.colors.accent)
        .lineLimit(1...6)
        .disabled(model.isDisabled)
        .focused($fieldFocused)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(theme.colors.inputFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(
                    fieldFocused ? theme.colors.accent : theme.colors.border,
                    lineWidth: fieldFocused ? 1.2 : AppMetrics.hairline
                )
        )
        .onKeyPress(keys: [.return]) { press in
            switch model.handleReturnKey(shiftPressed: press.modifiers.contains(.shift)) {
            case .ignored:
                return .ignored
            case .insertedNewline:
                return .handled
            case .submit:
                Task { await model.submit() }
                return .handled
            }
        }
        .accessibilityIdentifier("input-bar-field")
    }

    private var quickActionsButton: some View {
        // Two-phase timeline (§8.7): grow, then fade in; reversed on the way
        // out. Written as two scoped animations because SwiftUI has no single
        // curve that sequences two properties.
        Button { onOpenQuickActions?() } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 18))
                .foregroundStyle(theme.colors.muted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.showsQuickActions || onOpenQuickActions == nil)
        .opacity(model.showsQuickActions ? 1 : 0)
        .animation(
            .easeInOut(duration: 0.16).delay(model.showsQuickActions ? 0.16 : 0),
            value: model.showsQuickActions
        )
        .frame(width: model.showsQuickActions ? 38 : 0, alignment: .leading)
        .clipped()
        .animation(
            .easeInOut(duration: 0.16).delay(model.showsQuickActions ? 0 : 0.16),
            value: model.showsQuickActions
        )
        .accessibilityLabel("Quick actions")
        .accessibilityIdentifier("input-bar-quick-actions")
    }

    private var attachButton: some View {
        Button { model.openAttachSheet() } label: {
            Group {
                // The pick can take a visible moment: the system sheet, then a
                // resize and one to four JPEG passes. Without this the
                // paperclip just goes inert and reads as a dead button.
                if model.attachment.isPicking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(theme.colors.muted2)
                } else {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18))
                        .foregroundStyle(
                            model.attachEnabled
                                ? theme.colors.muted2 : theme.colors.muted.opacity(0.35)
                        )
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.attachEnabled)
        .accessibilityLabel("Attach image")
        .accessibilityIdentifier("input-bar-attach")
    }

    @ViewBuilder
    private var primaryButton: some View {
        let action = model.primaryAction
        // The mic and the send/stop button carry *different* gestures, and the
        // branch is structural rather than a disabled flag inside one gesture:
        // a zero-distance `DragGesture` left attached in send mode wins the
        // tap and the button stops working.
        if action == .sendAudio && !model.isDisabled {
            primaryButtonFace(action).gesture(micGesture)
        } else {
            primaryButtonFace(action)
                .onTapGesture { Task { await model.primaryTapped() } }
        }
    }

    private func primaryButtonFace(_ action: ComposerPrimaryAction) -> some View {
        let enabled = !model.isDisabled || action == .cancel
        return Circle()
            .fill(enabled ? theme.colors.accent : theme.colors.muted.opacity(0.3))
            .frame(width: 38, height: 38)
            .shadow(color: enabled ? theme.colors.accent.opacity(0.33) : .clear, radius: 8)
            .overlay {
                Image(systemName: action.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(enabled ? theme.colors.onAccent : theme.colors.muted)
                    .id(action)
                    .transition(.opacity.combined(with: .scale))
            }
            .animation(.easeOut(duration: 0.18), value: action)
            .contentShape(Circle())
            .accessibilityLabel(action.accessibilityLabel)
            .accessibilityIdentifier("input-bar-action")
            // This is a `Circle` with a gesture, not a `Button`, because the
            // mic branch needs a `DragGesture` a Button would swallow. Without
            // these two lines that costs the app its send button in
            // accessibility: no `.isButton` trait means VoiceOver announces it
            // as an image and offers no activation, and a `.onTapGesture` is
            // not an accessibility action — so assistive tech (and any UI
            // test) simply cannot press Send.
            //
            // `primaryTapped()` is the right action in all three modes: it
            // submits for `.sendText`, cancels for `.cancel`, and for
            // `.sendAudio` it only speaks the "hold to talk" explanation,
            // exactly as a bare tap does.
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { Task { await model.primaryTapped() } }
    }

    /// A zero-distance drag, not a `LongPressGesture`: only a drag reports the
    /// horizontal movement that arms slide-to-cancel, and the press→hold
    /// promotion (and its timing) lives in the model where it can be tested.
    private var micGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if value.translation == .zero {
                    model.micPressBegan()
                } else {
                    model.micPressMoved(dx: value.translation.width)
                }
            }
            .onEnded { _ in
                Task { await model.micPressEnded() }
            }
    }

    private var inlineStop: some View {
        Button { Task { await model.cancel() } } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 16))
                .foregroundStyle(theme.colors.error)
                .frame(width: 38, height: 38)
                .background(Circle().fill(theme.colors.error.opacity(0.14)))
                .overlay(Circle().stroke(theme.colors.error.opacity(0.55), lineWidth: AppMetrics.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop the current response")
        .accessibilityIdentifier("input-bar-inline-stop")
    }

    // MARK: Overlays

    @ViewBuilder
    private var strip: some View {
        Group {
            if case .recording(let elapsed, let level) = model.voice.state {
                RecordingStrip(
                    elapsed: elapsed,
                    level: level,
                    maxDuration: model.voice.maxDuration,
                    cancelArmed: model.voice.cancelArmed
                )
            } else {
                TranscribingStrip()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(theme.colors.bg)
        // Never let the strip take part in the gesture it is describing.
        .allowsHitTesting(false)
    }

    private func toastView(_ toast: ComposerToast) -> some View {
        HStack(spacing: 12) {
            Text(toast.message)
                .font(theme.type.mono(12))
                .foregroundStyle(theme.colors.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if toast.action == .openSettings {
                Button("Settings") { openAppSettings() }
                    .font(theme.type.mono(12, weight: .bold))
                    .foregroundStyle(theme.colors.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.colors.border, lineWidth: AppMetrics.hairline)
        )
        .padding(.bottom, 10)
        .onTapGesture { model.dismissToast() }
        .accessibilityIdentifier("composer-toast")
    }

    @ViewBuilder
    private var attachSheet: some View {
        let sheet = AttachSheet { source in
            Task { await model.pick(from: source) }
        }
        .presentationDetents([.height(180)])
        .presentationCornerRadius(AppMetrics.radiusSheetSmall)
        // Every chat-scoped sheet must close when the tablet's detail pane
        // swaps underneath it (§11.2), or it orphans over another session.
        if let selection {
            sheet.dismissOnSessionChange(selection)
        } else {
            sheet
        }
    }

    private func openAppSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
        #endif
    }
}

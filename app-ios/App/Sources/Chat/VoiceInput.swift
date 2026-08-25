import Foundation
import Observation
import SwiftUI

#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Speech)
import Speech
#endif

// ============================================================================
// Hold-to-talk voice input — spec 08 §8.9.
//
// idle → recording (while held) → transcribing (release OR the 60s cap) → idle
//
// Three things in here are load-bearing and easy to get wrong:
//
// 1. **The permission-prompt race is NOT reproduced.** The Flutter client asks
//    for microphone/speech authorization lazily inside `startRecording`, from
//    inside the long-press. The OS alert steals the press: the finger lifts to
//    tap "Allow", the release handler runs while the state is still `idle` and
//    no-ops, and then `startRecording` resolves and arms a recorder nobody is
//    holding. The Dart patches that after the fact by cancelling the phantom
//    recording (`input_bar.dart:229-249`). We instead never arm from a press
//    the OS is about to interrupt: ``VoiceInputModel/beginHold()`` resolves
//    authorization FIRST and, when it had to prompt, returns without touching
//    the engine and nudges the user to hold again. The Dart's phantom guard is
//    kept as well, because engine startup is async for other reasons too (an
//    audio-session activation can outlive a very short press).
//
// 2. **One funnel for transcripts.** Release and the 60s cap both go through
//    ``VoiceInputModel/finishAndTranscribe()``, which is the only caller of
//    `onTranscript`. Two paths would eventually mean the cap silently dropping
//    a transcript, which is exactly the bug the Dart's single broadcast stream
//    was built to prevent (`voice_input_viewmodel.dart:89-100`).
//
// 3. **The recognizer never auto-sends.** The transcript replaces the field
//    text and stops. Sending stays a deliberate tap.
// ============================================================================

// MARK: - State

enum VoiceUnavailableReason: Equatable, Sendable {
    /// Mic / speech permission denied. The mic stays visible and a tap guides
    /// the user to Settings.
    case permissionDenied
    /// No on-device recognizer for any acceptable locale. The mic is hidden
    /// entirely (spec §8.7 — `input_bar.dart:895-897`).
    case unsupported
}

enum VoiceInputState: Equatable, Sendable {
    case idle
    /// `level` is a 0…1 amplitude envelope, not a spectrum.
    case recording(elapsed: Duration, level: Double)
    case transcribing
    case unavailable(VoiceUnavailableReason)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isTranscribing: Bool { self == .transcribing }

    /// The strip covers the composer row for both busy states.
    var showsStrip: Bool { isRecording || isTranscribing }

    /// `unsupported` hides the mic button; `permissionDenied` does not.
    var hidesMicButton: Bool { self == .unavailable(.unsupported) }
}

/// One-shot hints the model asks its host to surface. Kept as values rather
/// than as calls into a presenter so the model stays testable and free of any
/// view plumbing (the Dart's `VoiceHint`, `input_bar.dart:29-35`).
enum VoiceHint: Equatable, Sendable {
    /// The user tapped the mic instead of holding it — also what we show right
    /// after a first-run permission grant, since the grant ate their press.
    case holdToTalk
    /// Microphone/speech access is off; offer a deep link to Settings.
    case permissionDenied
}

// MARK: - Engine seam

enum VoiceAuthorization: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    /// No on-device recognition available for any acceptable locale.
    case unsupported
}

/// Everything AVFoundation + Speech do, behind one protocol so the state
/// machine above is testable with no device, no simulator and no entitlement.
///
/// Mirrors the Dart `SpeechService` seam for the same reason.
@MainActor
protocol SpeechEngine: AnyObject {
    /// The cached status. Must NOT prompt.
    var authorization: VoiceAuthorization { get }
    /// Prompts if — and only if — the status is `.notDetermined`.
    func requestAuthorization() async -> VoiceAuthorization
    /// Begin capture. `onLevel` is called on the MainActor with a 0…1 envelope.
    func start(onLevel: @escaping @MainActor (Double) -> Void) async throws
    /// Stop capture and resolve the final transcript (`""` when there is none).
    func finish() async -> String
    /// Stop capture and discard whatever was heard.
    func cancel() async
}

// MARK: - Model

@MainActor
@Observable
final class VoiceInputModel {
    /// Hard cap on one recording (spec §8.9, decision #5).
    let maxDuration: Duration

    private(set) var state: VoiceInputState = .idle
    /// `true` once the drag has passed the cancel threshold. Owned here rather
    /// than in the strip because the strip is an `allowsHitTesting(false)`
    /// overlay: it must never take part in the gesture it is describing.
    private(set) var cancelArmed = false

    /// The single transcript funnel. Set by the composer.
    var onTranscript: (@MainActor (String) -> Void)?
    var onHint: (@MainActor (VoiceHint) -> Void)?

    /// How far left the press must slide to arm cancel (logical points).
    static let cancelThreshold: Double = 90

    private let engine: any SpeechEngine
    private let clock = ContinuousClock()
    private let tick: Duration
    private var startedAt: ContinuousClock.Instant?
    private var level: Double = 0
    private var ticker: Task<Void, Never>?
    /// `true` while the finger is down. Lets the arming path tell whether the
    /// press it was started by is still alive by the time the engine is up.
    private var holding = false
    /// Re-entrancy guard: a second `beginHold` must not start a second engine.
    private var arming = false

    init(
        engine: any SpeechEngine,
        maxDuration: Duration = .seconds(60),
        tick: Duration = .milliseconds(200)
    ) {
        self.engine = engine
        self.maxDuration = maxDuration
        self.tick = tick
    }

    /// Read the cached authorization without prompting. Call it when the
    /// composer appears so a device that already said no renders the right
    /// affordance on frame 1 instead of after the first futile hold.
    func prepare() {
        applyAuthorization(engine.authorization, hintOnDenial: false)
    }

    // MARK: Gesture

    /// The long-press began.
    ///
    /// Ordering here is the whole point: authorization is resolved BEFORE the
    /// recorder is armed. See the file header.
    func beginHold() async {
        holding = true
        cancelArmed = false
        guard !arming, !state.showsStrip else { return }

        let cached = engine.authorization
        if cached == .notDetermined {
            arming = true
            let resolved = await engine.requestAuthorization()
            arming = false
            // The system alert consumed the press — there is no finger left to
            // release, so arming now would produce a recording nobody can stop.
            // Tell the user to hold again instead.
            holding = false
            applyAuthorization(resolved, hintOnDenial: true)
            if resolved == .granted { onHint?(.holdToTalk) }
            return
        }

        applyAuthorization(cached, hintOnDenial: true)
        guard cached == .granted else { return }

        arming = true
        do {
            try await engine.start { [weak self] level in
                self?.applyLevel(level)
            }
        } catch {
            arming = false
            state = .idle
            return
        }
        arming = false

        // Belt and braces (the Dart's fix, `input_bar.dart:236-244`): audio
        // session activation is asynchronous for reasons other than the
        // permission alert, and a very short press can still end first.
        guard holding else {
            await engine.cancel()
            state = .idle
            return
        }

        startedAt = clock.now
        level = 0
        state = .recording(elapsed: .zero, level: 0)
        startTicker()
    }

    /// The long-press moved. `dx` is the horizontal offset from the press
    /// origin, so leftward is negative.
    func updateHold(dx: Double) {
        guard state.isRecording else { return }
        let armed = dx < -Self.cancelThreshold
        guard armed != cancelArmed else { return }
        cancelArmed = armed
    }

    /// The long-press ended: armed → discard, otherwise → transcribe.
    func endHold() async {
        holding = false
        let armed = cancelArmed
        cancelArmed = false
        guard state.isRecording else { return }
        if armed {
            await cancelRecording()
        } else {
            await finishAndTranscribe()
        }
    }

    /// A plain tap on the mic. Never records — it only explains the gesture.
    func tapped() {
        if case .unavailable(.permissionDenied) = state {
            onHint?(.permissionDenied)
            return
        }
        onHint?(.holdToTalk)
    }

    // MARK: Transitions

    /// The ONLY path that publishes a transcript. Both the release and the
    /// 60s cap come through here, so the cap can never drop one.
    ///
    /// Idempotent: a release racing the cap finds the state already off
    /// `.recording` and returns.
    func finishAndTranscribe() async {
        guard state.isRecording else { return }
        stopTicker()
        state = .transcribing
        let text = await engine.finish()
        state = .idle
        // An empty transcript is a no-op rather than a field-clobbering
        // assignment: the user said nothing, so leave what they typed alone.
        guard !text.isEmpty else { return }
        onTranscript?(text)
    }

    /// Slide-to-cancel. The field is left untouched.
    func cancelRecording() async {
        guard state.showsStrip else { return }
        stopTicker()
        await engine.cancel()
        state = .idle
    }

    /// Release the microphone when the composer goes away mid-recording.
    ///
    /// Synchronous on purpose so `onDisappear` can call it: the ticker dies
    /// immediately, and the engine teardown is the one fire-and-forget task in
    /// this file — dropping it would leave the audio session active and the
    /// red status bar up after the user navigated away.
    func teardown() {
        stopTicker()
        cancelArmed = false
        holding = false
        guard state.showsStrip else { return }
        state = .idle
        Task { [engine] in await engine.cancel() }
    }

    // MARK: Internals

    private func applyAuthorization(_ auth: VoiceAuthorization, hintOnDenial: Bool) {
        switch auth {
        case .granted:
            // Only clear an `unavailable` state — never stomp on a recording.
            if case .unavailable = state { state = .idle }
        case .denied:
            state = .unavailable(.permissionDenied)
            if hintOnDenial { onHint?(.permissionDenied) }
        case .unsupported:
            state = .unavailable(.unsupported)
        case .notDetermined:
            break
        }
    }

    private func applyLevel(_ next: Double) {
        level = min(max(next, 0), 1)
        guard case .recording(let elapsed, _) = state else { return }
        state = .recording(elapsed: elapsed, level: level)
    }

    private func startTicker() {
        // Cancel the task only — NOT `stopTicker()`, which also clears
        // `startedAt`. `beginHold` stamps the start instant immediately before
        // this call, so clearing it here would leave `advance()` permanently
        // guarded out and the 60s cap would never fire.
        ticker?.cancel()
        ticker = Task { [weak self, tick] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard let self, !Task.isCancelled else { return }
                await self.advance()
            }
        }
    }

    private func advance() async {
        guard case .recording = state, let startedAt else { return }
        // Elapsed is read off a monotonic clock rather than accumulated one
        // tick at a time: an accumulator drifts whenever the app is throttled
        // or a tick is late, and the 60s cap is a promise about wall time.
        let elapsed = clock.now - startedAt
        if elapsed >= maxDuration {
            await finishAndTranscribe()
            return
        }
        state = .recording(elapsed: elapsed, level: level)
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
        startedAt = nil
    }
}

// MARK: - Live engine

#if os(iOS)

/// AVAudioEngine + on-device `SFSpeechRecognizer`.
///
/// Everything platform-specific lives here so ``VoiceInputModel`` can be
/// exercised in a plain unit test.
@MainActor
final class SystemSpeechEngine: SpeechEngine {
    private let recognizer: SFSpeechRecognizer?
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcripts: AsyncStream<String>.Continuation?
    private var latest = ""
    private var levelPump: Task<Void, Never>?

    init(locale: Locale = .current) {
        let candidate = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
        // On-device only: dictation into a coding agent should not be shipped
        // to Apple's servers, and the spec's 60s cap assumes local latency.
        self.recognizer = (candidate?.supportsOnDeviceRecognition ?? false) ? candidate : nil
    }

    var authorization: VoiceAuthorization {
        guard recognizer != nil else { return .unsupported }
        let speech = SFSpeechRecognizer.authorizationStatus()
        let mic = AVAudioApplication.shared.recordPermission
        switch (speech, mic) {
        case (.authorized, .granted):
            return .granted
        case (.denied, _), (.restricted, _), (_, .denied):
            return .denied
        default:
            return .notDetermined
        }
    }

    func requestAuthorization() async -> VoiceAuthorization {
        guard recognizer != nil else { return .unsupported }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speech == .authorized else { return .denied }
        let mic = await AVAudioApplication.requestRecordPermission()
        return mic ? .granted : .denied
    }

    func start(onLevel: @escaping @MainActor (Double) -> Void) async throws {
        guard let recognizer else { throw VoiceEngineError.unsupported }
        try AVAudioSession.sharedInstance().setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.duckOthers, .defaultToSpeaker]
        )
        try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request
        latest = ""

        let (stream, continuation) = AsyncStream<String>.makeStream()
        transcripts = continuation
        task = recognizer.recognitionTask(with: request) { result, _ in
            // Only a `String` crosses the boundary: `SFSpeechRecognitionResult`
            // is not Sendable and the handler runs off the main actor.
            guard let text = result?.bestTranscription.formattedString else { return }
            continuation.yield(text)
        }

        // Levels come off the realtime audio thread, so they ride an
        // AsyncStream (whose continuation *is* Sendable) instead of a captured
        // closure hopping actors on every buffer.
        let (levels, levelSink) = AsyncStream<Double>.makeStream()
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
            levelSink.yield(Self.envelope(of: buffer))
        }
        audio.prepare()
        try audio.start()

        levelPump = Task { @MainActor in
            for await value in levels {
                if Task.isCancelled { return }
                onLevel(value)
            }
        }

        // Keep the newest transcript so `finish()` has something to return even
        // if the final callback never lands.
        Task { @MainActor [weak self] in
            for await text in stream {
                self?.latest = text
            }
        }
    }

    func finish() async -> String {
        stopCapture()
        request?.endAudio()
        // On-device finalisation is fast; a short grace window is enough to
        // pick up the last partial without making the strip feel stuck.
        try? await Task.sleep(for: .milliseconds(400))
        let text = latest
        teardownTask()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        stopCapture()
        latest = ""
        teardownTask()
    }

    private func stopCapture() {
        levelPump?.cancel()
        levelPump = nil
        if audio.isRunning {
            audio.stop()
            audio.inputNode.removeTap(onBus: 0)
        }
    }

    private func teardownTask() {
        task?.cancel()
        task = nil
        request = nil
        transcripts?.finish()
        transcripts = nil
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
    }

    /// RMS → dBFS → 0…1. Matched to speech, not to music: −50 dB is the floor.
    private nonisolated static func envelope(of buffer: AVAudioPCMBuffer) -> Double {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return Double(min(max((db + 50) / 50, 0), 1))
    }
}

enum VoiceEngineError: Error {
    case unsupported
}

#endif

/// The engine used where there is no microphone stack to talk to (the macOS
/// unit-test host). Reports `unsupported`, which hides the mic button.
@MainActor
final class UnsupportedSpeechEngine: SpeechEngine {
    var authorization: VoiceAuthorization { .unsupported }
    func requestAuthorization() async -> VoiceAuthorization { .unsupported }
    func start(onLevel: @escaping @MainActor (Double) -> Void) async throws {}
    func finish() async -> String { "" }
    func cancel() async {}

    init() {}
}

/// The engine the app actually installs.
@MainActor
func makeSystemSpeechEngine() -> any SpeechEngine {
    #if os(iOS)
    SystemSpeechEngine()
    #else
    UnsupportedSpeechEngine()
    #endif
}

// MARK: - Strips

/// The WhatsApp-style strip that covers the composer row while recording
/// (spec §8.9). Purely presentational — it renders `elapsed`/`level`/
/// `cancelArmed` and fires nothing, because the gesture is owned by the mic
/// button underneath and must survive the row→strip swap.
struct RecordingStrip: View {
    let elapsed: Duration
    let level: Double
    let maxDuration: Duration
    let cancelArmed: Bool

    /// Emphasise the timer this close to the cap.
    static let warnBefore: Duration = .seconds(10)
    /// Bars kept in the rolling waveform.
    static let barCount = 28

    @Environment(\.theme) private var theme
    @State private var samples: [Double] = []
    @State private var pulse = false

    private var isWarning: Bool { maxDuration - elapsed <= Self.warnBefore }

    private var timerColor: Color {
        if cancelArmed { return theme.colors.muted }
        return isWarning ? theme.colors.warning : theme.colors.text
    }

    private var timer: String {
        let total = max(Int(elapsed.components.seconds), 0)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(theme.colors.error)
                .frame(width: 11, height: 11)
                .opacity(pulse ? 0.25 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            Text(timer)
                .font(theme.type.mono(12, weight: .medium))
                .foregroundStyle(timerColor)
                .monospacedDigit()
            waveform
            Spacer(minLength: 8)
            Text(cancelArmed ? "release to cancel" : "‹ slide to cancel")
                .font(theme.type.mono(11))
                .foregroundStyle(cancelArmed ? theme.colors.error : theme.colors.muted)
        }
        .onAppear {
            pulse = true
            push(level)
        }
        .onChange(of: level) { _, next in push(next) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording, \(timer). Slide left to cancel.")
    }

    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(cancelArmed ? theme.colors.muted : theme.colors.accent)
                    .frame(width: 2, height: max(3, sample * 18))
            }
        }
        .frame(height: 18)
    }

    private func push(_ value: Double) {
        samples.append(min(max(value, 0), 1))
        if samples.count > Self.barCount {
            samples.removeFirst(samples.count - Self.barCount)
        }
    }
}

/// The short-lived state between release and the finalised transcript.
struct TranscribingStrip: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(theme.colors.accent)
            Text("transcribing…")
                .font(theme.type.mono(12))
                .foregroundStyle(theme.colors.muted2)
        }
        .frame(maxWidth: .infinity)
    }
}

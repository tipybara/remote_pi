import Foundation
import Testing

#if canImport(ComposerHarness)
@testable import ComposerHarness
#else
@testable import RemotePi
#endif

@MainActor
private func makeVoice(
    _ engine: FakeSpeechEngine,
    maxDuration: Duration = .seconds(60),
    tick: Duration = .milliseconds(20)
) -> VoiceInputModel {
    VoiceInputModel(engine: engine, maxDuration: maxDuration, tick: tick)
}

@MainActor
@Suite("Voice authorization — the prompt race is NOT reproduced (spec 08 §8.9)")
struct VoiceAuthorizationTests {
    /// The whole point of this file. The Flutter client asks for permission
    /// from inside the long-press; the system alert steals the press and a
    /// recorder is armed with nobody holding it. Here the first hold prompts
    /// and stops.
    @Test("A first hold prompts and never arms the recorder")
    func firstHoldPromptsOnly() async {
        let engine = FakeSpeechEngine()
        engine.authorization = .notDetermined
        engine.authorizationAfterPrompt = .granted
        let voice = makeVoice(engine)
        let recorder = Recorder()
        var hints: [VoiceHint] = []
        voice.onHint = { hints.append($0) }
        voice.onTranscript = { recorder.transcripts.append($0) }

        await voice.beginHold()

        #expect(engine.promptCount == 1)
        #expect(engine.startCount == 0, "the recorder must not be armed from the stolen press")
        #expect(voice.state == .idle)
        #expect(hints == [.holdToTalk], "the user is told to hold again")

        // The press that was consumed by the alert releases into nothing.
        await voice.endHold()
        #expect(engine.finishCount == 0)
        #expect(recorder.transcripts.isEmpty)

        // The next hold works, because authorization is now cached.
        await voice.beginHold()
        #expect(engine.startCount == 1)
        #expect(voice.state.isRecording)
    }

    @Test("A denied prompt lands on permissionDenied and hints once")
    func deniedPrompt() async {
        let engine = FakeSpeechEngine()
        engine.authorization = .notDetermined
        engine.authorizationAfterPrompt = .denied
        let voice = makeVoice(engine)
        var hints: [VoiceHint] = []
        voice.onHint = { hints.append($0) }

        await voice.beginHold()

        #expect(voice.state == .unavailable(.permissionDenied))
        #expect(engine.startCount == 0)
        #expect(hints == [.permissionDenied])
        #expect(!voice.state.hidesMicButton, "a denied mic stays visible")
    }

    @Test("No on-device recogniser hides the mic entirely")
    func unsupported() {
        let engine = FakeSpeechEngine()
        engine.authorization = .unsupported
        let voice = makeVoice(engine)
        voice.prepare()

        #expect(voice.state == .unavailable(.unsupported))
        #expect(voice.state.hidesMicButton)
    }

    @Test("prepare() reads the cached status and never prompts")
    func prepareDoesNotPrompt() {
        let engine = FakeSpeechEngine()
        engine.authorization = .notDetermined
        let voice = makeVoice(engine)
        voice.prepare()

        #expect(engine.promptCount == 0)
        #expect(voice.state == .idle, "unknown permission renders as a normal, usable mic")
    }

    @Test("A regained permission clears the unavailable state")
    func regainedPermission() async {
        let engine = FakeSpeechEngine()
        engine.authorization = .denied
        let voice = makeVoice(engine)
        voice.prepare()
        #expect(voice.state == .unavailable(.permissionDenied))

        engine.authorization = .granted
        voice.prepare()
        #expect(voice.state == .idle)
    }
}

@MainActor
@Suite("Voice recording lifecycle")
struct VoiceRecordingTests {
    @Test("Release transcribes through the single funnel")
    func releaseTranscribes() async {
        let engine = FakeSpeechEngine()
        engine.transcript = "add a test"
        let voice = makeVoice(engine)
        let recorder = Recorder()
        voice.onTranscript = { recorder.transcripts.append($0) }

        await voice.beginHold()
        #expect(voice.state.isRecording)
        #expect(voice.state.showsStrip)

        await voice.endHold()

        #expect(engine.finishCount == 1)
        #expect(recorder.transcripts == ["add a test"])
        #expect(voice.state == .idle)
    }

    @Test("The duration cap goes through the SAME funnel as a release")
    func capUsesTheSameFunnel() async {
        let engine = FakeSpeechEngine()
        engine.transcript = "capped"
        let voice = makeVoice(engine, maxDuration: .milliseconds(80), tick: .milliseconds(10))
        let recorder = Recorder()
        voice.onTranscript = { recorder.transcripts.append($0) }

        await voice.beginHold()
        await waitUntil("the cap fired") { voice.state == .idle }

        #expect(engine.finishCount == 1, "the cap must transcribe, not discard")
        #expect(recorder.transcripts == ["capped"])
    }

    @Test("A release racing the cap delivers exactly one transcript")
    func releaseRacingTheCap() async {
        let engine = FakeSpeechEngine()
        let voice = makeVoice(engine, maxDuration: .milliseconds(60), tick: .milliseconds(10))
        let recorder = Recorder()
        voice.onTranscript = { recorder.transcripts.append($0) }

        await voice.beginHold()
        await voice.finishAndTranscribe()
        await voice.finishAndTranscribe()
        await voice.endHold()

        #expect(engine.finishCount == 1)
        #expect(recorder.transcripts.count == 1)
    }

    @Test("An empty transcript is not published")
    func emptyTranscript() async {
        let engine = FakeSpeechEngine()
        engine.transcript = ""
        let voice = makeVoice(engine)
        let recorder = Recorder()
        voice.onTranscript = { recorder.transcripts.append($0) }

        await voice.beginHold()
        await voice.endHold()

        #expect(recorder.transcripts.isEmpty)
        #expect(voice.state == .idle)
    }

    @Test("Slide-to-cancel discards, and the threshold is 90pt")
    func slideToCancel() async {
        let engine = FakeSpeechEngine()
        let voice = makeVoice(engine)
        let recorder = Recorder()
        voice.onTranscript = { recorder.transcripts.append($0) }

        await voice.beginHold()
        voice.updateHold(dx: -89)
        #expect(!voice.cancelArmed)
        voice.updateHold(dx: -91)
        #expect(voice.cancelArmed)
        voice.updateHold(dx: -10)
        #expect(!voice.cancelArmed, "sliding back disarms")
        voice.updateHold(dx: -200)
        #expect(voice.cancelArmed)

        await voice.endHold()

        #expect(engine.cancelCount == 1)
        #expect(engine.finishCount == 0)
        #expect(recorder.transcripts.isEmpty)
        #expect(voice.state == .idle)
    }

    @Test("A press that ends before the engine is up leaves no phantom recording")
    func phantomRecordingIsDiscarded() async {
        // The Dart's own guard (`input_bar.dart:236-244`), kept because engine
        // startup is asynchronous for reasons other than a permission alert.
        let engine = FakeSpeechEngine()
        engine.suspendStart = true
        let voice = makeVoice(engine)

        let hold = Task { await voice.beginHold() }
        await waitUntil("engine start entered") { engine.startCount == 1 }

        await voice.endHold()  // the finger lifted while start was still in flight
        engine.releaseStart()
        await hold.value

        #expect(engine.cancelCount == 1, "the phantom recording is discarded")
        #expect(voice.state == .idle)
    }

    @Test("A failed engine start returns to idle rather than a stuck strip")
    func failedStart() async {
        let engine = FakeSpeechEngine()
        engine.startError = FakeSpeechFailure()
        let voice = makeVoice(engine)

        await voice.beginHold()

        #expect(voice.state == .idle)
        #expect(!voice.state.showsStrip)
    }

    @Test("A level update keeps the elapsed time it was given")
    func levelUpdates() async {
        let engine = FakeSpeechEngine()
        let voice = makeVoice(engine, tick: .seconds(30))  // no ticks during the test
        await voice.beginHold()

        engine.levelSink?(0.7)
        #expect(voice.state == .recording(elapsed: .zero, level: 0.7))

        engine.levelSink?(4)
        #expect(voice.state == .recording(elapsed: .zero, level: 1), "levels are clamped to 0…1")
    }

    @Test("teardown releases the microphone")
    func teardown() async {
        let engine = FakeSpeechEngine()
        let voice = makeVoice(engine)
        await voice.beginHold()
        #expect(voice.state.isRecording)

        voice.teardown()
        #expect(voice.state == .idle)
        await waitUntil("engine cancelled") { engine.cancelCount == 1 }
    }

    @Test("A tap while denied re-offers the Settings hint")
    func tapWhileDenied() {
        let engine = FakeSpeechEngine()
        engine.authorization = .denied
        let voice = makeVoice(engine)
        var hints: [VoiceHint] = []
        voice.onHint = { hints.append($0) }

        voice.prepare()
        hints.removeAll()
        voice.tapped()

        #expect(hints == [.permissionDenied])
    }
}

@MainActor
@Suite("Recording strip formatting")
struct RecordingStripTests {
    @Test("The warn window is the last 10 seconds")
    func warnWindow() {
        #expect(RecordingStrip.warnBefore == .seconds(10))
        #expect(RecordingStrip.barCount == 28)
    }
}

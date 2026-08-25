import Foundation
import Testing

#if canImport(ComposerHarness)
@testable import ComposerHarness
#else
@testable import RemotePi
#endif

@MainActor
@Suite("Composer gating (spec 08 §8.7)")
struct ComposerGateTests {
    @Test("Every host reason locks the composer")
    func disabledReasons() {
        #expect(ComposerGate().isDisabled, "not ready is disabled")
        #expect(!liveGate.isDisabled)
        #expect(ComposerGate(isReady: true, isOffline: true).isDisabled)
        #expect(ComposerGate(isReady: true, pairingRevoked: true).isDisabled)
        #expect(ComposerGate(isReady: true, peerOfflineReason: "peer_stop").isDisabled)
        #expect(ComposerGate(isReady: true, presenceOffline: true).isDisabled)
    }

    @Test("Quick actions and attach follow the field")
    func actionsFollowField() {
        #expect(liveGate.actionsEnabled)
        #expect(!ComposerGate(isReady: true, isOffline: true).actionsEnabled)
    }
}

@MainActor
@Suite("Composer placeholder + primary action")
struct ComposerSurfaceTests {
    @Test("Placeholder priority: disabled → steering → caption → default")
    func placeholder() async {
        let fixture = makeComposer()
        let model = fixture.model

        model.apply(ComposerGate())
        #expect(model.placeholder == "Offline…")

        // Disabled outranks working: an offline composer says why it is dead,
        // not what it would do if it were alive.
        model.apply(ComposerGate(isWorking: true))
        #expect(model.placeholder == "Offline…")

        model.apply(ComposerGate(isReady: true, isWorking: true))
        #expect(model.placeholder == "Steer current response…")

        model.apply(liveGate)
        #expect(model.placeholder == "Send a message…")

        await fixture.attach()
        #expect(model.placeholder == "Add a caption…")
    }

    @Test("Primary action modes")
    func primaryAction() async {
        let fixture = makeComposer()
        let model = fixture.model
        model.apply(liveGate)
        #expect(model.primaryAction == .sendAudio)

        model.draft = "hi"
        #expect(model.primaryAction == .sendText)

        model.draft = ""
        model.apply(ComposerGate(isReady: true, isWorking: true, cancelTargetID: "u1"))
        #expect(model.primaryAction == .cancel, "working + empty is Stop")

        model.draft = "steer me"
        #expect(model.primaryAction == .sendText, "working + content is Send, not Stop")

        model.draft = ""
        model.apply(liveGate)
        await fixture.attach()
        #expect(model.primaryAction == .sendText, "an image alone is content")
    }

    @Test("The mic is hidden only when no recogniser exists")
    func micVisibility() async {
        let fixture = makeComposer()
        fixture.engine.authorization = .unsupported
        fixture.model.apply(liveGate)
        fixture.model.activate()
        #expect(fixture.model.hidesPrimaryAction)

        fixture.model.draft = "typed"
        #expect(!fixture.model.hidesPrimaryAction, "send is never hidden")

        let denied = makeComposer()
        denied.engine.authorization = .denied
        denied.model.apply(liveGate)
        denied.model.activate()
        #expect(
            !denied.model.hidesPrimaryAction,
            "a denied mic stays visible so it can explain itself"
        )
    }

    @Test("Quick actions show only on an empty, idle, live composer")
    func quickActionsVisibility() async {
        let fixture = makeComposer()
        let model = fixture.model
        model.apply(liveGate)
        #expect(model.showsQuickActions)

        model.draft = "x"
        #expect(!model.showsQuickActions)
        model.draft = ""

        model.apply(ComposerGate(isReady: true, isWorking: true))
        #expect(!model.showsQuickActions)

        model.apply(liveGate)
        await fixture.attach()
        #expect(!model.showsQuickActions)
    }

    @Test("Attach enablement, including the tri-state vision gate")
    func attachEnablement() async {
        let fixture = makeComposer()
        let model = fixture.model
        model.apply(liveGate)
        #expect(model.attachEnabled, "unknown vision must NOT gate the paperclip")

        model.attachment.applyVision(true)
        #expect(model.attachEnabled)

        model.attachment.applyVision(false)
        #expect(!model.attachEnabled, "a known text-only model greys it out")

        model.attachment.applyVision(nil)
        #expect(model.attachEnabled, "falling back to unknown re-enables it")

        model.apply(ComposerGate(isReady: true, isWorking: true))
        #expect(!model.attachEnabled)

        model.apply(liveGate)
        await fixture.attach()
        #expect(!model.attachEnabled, "one image at a time")
    }

    @Test("Inline Stop appears only while steering with content")
    func inlineStop() {
        let model = makeComposer().model
        model.apply(ComposerGate(isReady: true, isWorking: true, cancelTargetID: "u1"))
        #expect(!model.showsInlineStop, "empty field: the primary button is already Stop")

        model.draft = "redirect"
        #expect(model.showsInlineStop)

        model.apply(ComposerGate(isReady: true, isWorking: true))
        #expect(!model.showsInlineStop, "nothing to cancel")

        model.apply(liveGate)
        #expect(!model.showsInlineStop)
    }
}

@MainActor
@Suite("Composer send — steer vs queue (spec 08 §8.8)")
struct ComposerSendTests {
    @Test("An idle send carries no steering behaviour")
    func idleSend() async {
        let fixture = makeComposer()
        fixture.model.apply(liveGate)
        fixture.model.draft = "  hello  "
        await fixture.model.submit()

        #expect(fixture.host.sent == [.init(text: "hello", image: nil, steer: false)])
        #expect(fixture.model.draft.isEmpty)
    }

    @Test("Sending during a turn STEERS — it is not queued and not blocked")
    func steerWhileWorking() async {
        let fixture = makeComposer()
        fixture.model.apply(
            ComposerGate(isReady: true, isWorking: true, cancelTargetID: "u1")
        )
        fixture.model.draft = "actually, use tabs"
        await fixture.model.submit()

        #expect(fixture.host.sent.count == 1)
        #expect(
            fixture.host.sent[0].steer,
            "a send while working must set streaming_behavior: steer"
        )
        // The queue is a different mechanism entirely and must stay untouched.
        #expect(fixture.host.queuedSets.isEmpty)
        #expect(fixture.model.queued.items.isEmpty)
    }

    @Test("Nothing to send is a no-op")
    func emptySend() async {
        let fixture = makeComposer()
        fixture.model.apply(liveGate)
        fixture.model.draft = "   \n  "
        await fixture.model.submit()
        #expect(fixture.host.sent.isEmpty)
    }

    @Test("An image with an empty caption is a valid send, and is taken once")
    func imageOnlySend() async {
        let fixture = makeComposer()
        fixture.model.apply(liveGate)
        await fixture.attach()

        await fixture.model.submit()
        #expect(fixture.host.sent == [.init(text: "", image: plusSlashImage, steer: false)])
        #expect(!fixture.model.hasImage)

        // A double-tapped send must not ship the same attachment twice.
        await fixture.model.submit()
        #expect(fixture.host.sent.count == 1)
    }

    @Test("Cancel targets the id the host resolved, and no-ops without one")
    func cancel() async {
        let fixture = makeComposer()
        fixture.model.apply(
            ComposerGate(isReady: true, isWorking: true, cancelTargetID: "user-7")
        )
        await fixture.model.cancel()
        #expect(fixture.host.cancelled == ["user-7"])

        fixture.model.apply(liveGate)
        await fixture.model.cancel()
        #expect(fixture.host.cancelled == ["user-7"])
    }

    @Test("Primary tap routes by mode")
    func primaryTap() async {
        let fixture = makeComposer()
        let model = fixture.model
        model.apply(ComposerGate(isReady: true, isWorking: true, cancelTargetID: "u9"))
        await model.primaryTapped()
        #expect(fixture.host.cancelled == ["u9"])

        model.draft = "go"
        await model.primaryTapped()
        #expect(fixture.host.sent.count == 1)

        model.apply(liveGate)
        model.activate()
        await model.primaryTapped()
        #expect(
            model.toast?.message == "Hold the mic to talk",
            "a bare tap on the mic explains itself"
        )
        model.deactivate()
    }
}

@MainActor
@Suite("Composer hardware keyboard (spec 08 §8.7)")
struct ComposerKeyboardTests {
    @Test("Plain Return submits, Shift+Return newlines, disabled ignores")
    func returnKey() {
        let model = makeComposer().model
        model.apply(ComposerGate())
        #expect(model.handleReturnKey(shiftPressed: false) == .ignored)

        model.apply(liveGate)
        model.draft = "line"
        #expect(model.handleReturnKey(shiftPressed: true) == .insertedNewline)
        #expect(model.draft == "line\n")
        #expect(model.handleReturnKey(shiftPressed: false) == .submit)
    }
}

@MainActor
@Suite("Composer queued-message interaction (spec 08 §8.8)")
struct ComposerQueuedTests {
    @Test("Tapping an editable item pulls it back and clears it on the Pi")
    func editQueued() async {
        let fixture = makeComposer()
        let model = fixture.model
        model.apply(liveGate)
        model.queued.apply(.init(items: [.init(id: "q1", text: "and add tests", editable: true)]))

        let before = model.focusToken
        await model.editQueued(model.queued.items[0])

        #expect(model.draft == "and add tests")
        #expect(model.queued.items.isEmpty)
        #expect(fixture.host.queuedClears == ["q1"])
        #expect(model.focusToken != before, "the field must take focus with the recovered text")
    }

    @Test("A non-editable item is inert")
    func nonEditableQueued() async {
        let fixture = makeComposer()
        let model = fixture.model
        model.queued.apply(.init(items: [.init(id: "q2", text: "committed", editable: false)]))

        await model.editQueued(model.queued.items[0])
        #expect(model.draft.isEmpty)
        #expect(model.queued.items.count == 1)
        #expect(fixture.host.queuedClears.isEmpty)
    }

    @Test("The ✕ clears just that item")
    func clearQueued() async {
        let fixture = makeComposer()
        let model = fixture.model
        model.queued.apply(
            .init(items: [.init(id: "q1", text: "one"), .init(id: "q2", text: "two")])
        )
        await model.clearQueued(model.queued.items[0])
        #expect(model.queued.items.map(\.id) == ["q2"])
        #expect(fixture.host.queuedClears == ["q1"])
    }
}

@MainActor
@Suite("Composer transcripts, toasts and session hygiene")
struct ComposerStateTests {
    @Test("A transcript replaces the field and takes focus; an empty one does not")
    func transcript() async {
        let fixture = makeComposer()
        let model = fixture.model
        model.apply(liveGate)
        model.activate()

        model.draft = "stale"
        model.voice.onTranscript?("dictated text")
        #expect(model.draft == "dictated text")

        model.voice.onTranscript?("")
        #expect(model.draft == "dictated text", "silence must not clobber the field")
        model.deactivate()
    }

    @Test("Permission denials surface a Settings toast; a failed pick does not")
    func toasts() async {
        let fixture = makeComposer()
        let model = fixture.model
        model.apply(liveGate)
        model.activate()

        fixture.picker.result = .failure(ImagePermissionDenied())
        await model.pick(from: .camera)
        #expect(
            model.toast?.message
                == "Camera access is off — enable it in Settings to attach a photo."
        )
        #expect(model.toast?.action == .openSettings)
        #expect(model.toast?.duration == .seconds(5))

        fixture.picker.result = .failure(FakeSpeechFailure())
        await model.pick(from: .gallery)
        #expect(model.toast?.message == "Couldn't attach that image.")
        #expect(model.toast?.action == ComposerToast.Action.none)

        model.dismissToast()
        #expect(model.toast == nil)

        fixture.engine.authorization = .denied
        model.voice.prepare()
        model.voice.tapped()
        #expect(model.toast?.action == .openSettings)
        #expect(model.toast?.message.hasPrefix("Microphone access is off") == true)

        model.deactivate()
    }

    @Test("A session switch drops the draft, the attachment and the queue")
    func sessionReset() async {
        let fixture = makeComposer()
        let model = fixture.model
        model.apply(liveGate)
        model.draft = "half typed"
        await fixture.attach()
        model.queued.apply(.init(items: [.init(id: "q1", text: "later")]))

        model.resetForSessionChange()

        #expect(model.draft.isEmpty)
        #expect(!model.hasImage)
        #expect(model.queued.items.isEmpty)
        #expect(model.toast == nil)
    }
}

@MainActor
@Suite("Composer hold-to-talk gesture (spec 08 §8.9)")
struct ComposerMicGestureTests {
    @Test("A quick press is a tap, not a recording")
    func quickTap() async {
        let fixture = makeComposer(holdDelay: .milliseconds(300))
        let model = fixture.model
        model.apply(liveGate)
        model.activate()

        model.micPressBegan()
        await model.micPressEnded()

        #expect(fixture.engine.startCount == 0, "a tap must never arm the recorder")
        #expect(model.toast?.message == "Hold the mic to talk")
        model.deactivate()
    }

    @Test("Hold, release → the transcript lands in the field")
    func holdAndRelease() async {
        let fixture = makeComposer()
        fixture.engine.transcript = "run the tests"
        let model = fixture.model
        model.apply(liveGate)
        model.activate()

        model.micPressBegan()
        await waitUntil("recording started") { model.voice.state.isRecording }
        await model.micPressEnded()

        #expect(fixture.engine.finishCount == 1)
        #expect(model.draft == "run the tests")
        #expect(model.voice.state == .idle)
        model.deactivate()
    }

    @Test("Sliding past the threshold and releasing discards the recording")
    func slideToCancel() async {
        let fixture = makeComposer()
        let model = fixture.model
        model.apply(liveGate)
        model.activate()

        model.micPressBegan()
        await waitUntil("recording started") { model.voice.state.isRecording }

        model.micPressMoved(dx: -40)
        #expect(!model.voice.cancelArmed, "40pt is short of the 90pt threshold")
        model.micPressMoved(dx: -120)
        #expect(model.voice.cancelArmed)

        await model.micPressEnded()

        #expect(fixture.engine.cancelCount == 1)
        #expect(fixture.engine.finishCount == 0, "a cancelled recording must not be transcribed")
        #expect(model.draft.isEmpty)
        #expect(!model.voice.cancelArmed)
        model.deactivate()
    }
}

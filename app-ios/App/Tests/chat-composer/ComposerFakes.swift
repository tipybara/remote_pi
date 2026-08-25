import Foundation
import Testing

// The composer sources live in the app target (`RemotePi`). They are also
// mirrored into a small SwiftPM harness so this suite can run with `swift test`
// on the command line while `project.yml` still has no app test bundle — see
// the report accompanying this directory.
#if canImport(ComposerHarness)
@testable import ComposerHarness
#else
@testable import RemotePi
#endif

// MARK: - Host

@MainActor
final class FakeComposerHost: ComposerHost {
    struct Sent: Equatable {
        let text: String
        let image: ComposerImage?
        let steer: Bool
    }

    struct QueuedSet: Equatable {
        let id: String
        let text: String
    }

    private(set) var sent: [Sent] = []
    private(set) var cancelled: [String] = []
    private(set) var queuedSets: [QueuedSet] = []
    private(set) var queuedClears: [String?] = []

    func composerSend(text: String, image: ComposerImage?, steer: Bool) async {
        sent.append(Sent(text: text, image: image, steer: steer))
    }

    func composerCancel(targetID: String) async {
        cancelled.append(targetID)
    }

    func queuedMessageSet(id: String, text: String) async {
        queuedSets.append(QueuedSet(id: id, text: text))
    }

    func queuedMessageClear(targetID: String?) async {
        queuedClears.append(targetID)
    }
}

// MARK: - Speech

@MainActor
final class FakeSpeechEngine: SpeechEngine {
    var authorization: VoiceAuthorization = .granted
    /// What ``requestAuthorization()`` resolves to (and caches).
    var authorizationAfterPrompt: VoiceAuthorization = .granted
    var startError: Error?
    var transcript = "hello there"

    private(set) var promptCount = 0
    private(set) var startCount = 0
    private(set) var finishCount = 0
    private(set) var cancelCount = 0

    /// When true, `start` suspends until ``releaseStart()``. Used to reproduce
    /// the window where the press can end before the engine is up.
    var suspendStart = false
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var levelSink: (@MainActor (Double) -> Void)?

    func requestAuthorization() async -> VoiceAuthorization {
        promptCount += 1
        authorization = authorizationAfterPrompt
        return authorization
    }

    func start(onLevel: @escaping @MainActor (Double) -> Void) async throws {
        startCount += 1
        levelSink = onLevel
        if let startError { throw startError }
        if suspendStart {
            await withCheckedContinuation { gate = $0 }
        }
    }

    func releaseStart() {
        gate?.resume()
        gate = nil
    }

    func finish() async -> String {
        finishCount += 1
        return transcript
    }

    func cancel() async {
        cancelCount += 1
    }
}

struct FakeSpeechFailure: Error {}

// MARK: - Images

@MainActor
final class FakeImagePicker: ImagePicking {
    var result: Result<ComposerImage?, Error> = .success(nil)
    private(set) var requested: [AttachSource] = []

    func pick(from source: AttachSource) async throws -> ComposerImage? {
        requested.append(source)
        return try result.get()
    }
}

// MARK: - Recording side effects

@MainActor
final class Recorder {
    var transcripts: [String] = []
}

// MARK: - Helpers

/// Polls until `condition` holds. Everything under test is driven by real
/// `Task.sleep` timers (the hold delay, the recording ticker), so the suite
/// waits on the condition rather than on a fixed duration.
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(3),
    _ condition: @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for: \(description)")
}

/// One composer plus the three fakes it is wired to, so a test can steer the
/// picker or the speech engine after construction.
@MainActor
struct ComposerFixture {
    let model: ComposerModel
    let host: FakeComposerHost
    let picker: FakeImagePicker
    let engine: FakeSpeechEngine

    /// Attach an image through the real pick path.
    func attach(_ image: ComposerImage = plusSlashImage) async {
        picker.result = .success(image)
        await model.attachment.pick(from: .gallery)
    }
}

@MainActor
func makeComposer(holdDelay: Duration = .milliseconds(15)) -> ComposerFixture {
    let host = FakeComposerHost()
    let picker = FakeImagePicker()
    let engine = FakeSpeechEngine()
    let model = ComposerModel(
        host: host,
        attachment: AttachmentModel(picker: picker),
        voice: VoiceInputModel(engine: engine, maxDuration: .seconds(60), tick: .milliseconds(20)),
        queued: QueuedMessagesModel(sink: host),
        holdDelay: holdDelay
    )
    return ComposerFixture(model: model, host: host, picker: picker, engine: engine)
}

/// Bytes whose STANDARD base64 is `+/+/` and whose base64url spelling would be
/// `-_-_`. Used to prove the image encoder is not the URL-safe alphabet.
let plusSlashImage = ComposerImage(data: Data([0xFB, 0xFF, 0xBF]), mime: "image/jpeg")

let liveGate = ComposerGate(isReady: true)

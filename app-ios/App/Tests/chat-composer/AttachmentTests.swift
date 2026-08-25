import Foundation
import RemotePiProtocol
import Testing

#if canImport(ComposerHarness)
@testable import ComposerHarness
#else
@testable import RemotePi
#endif

@MainActor
@Suite("Image attachment (spec 08 §8.10)")
struct AttachmentModelTests {
    @Test("A successful pick attaches, and takeImageForSend reads-and-clears")
    func pickAndTake() async {
        let picker = FakeImagePicker()
        picker.result = .success(plusSlashImage)
        let model = AttachmentModel(picker: picker)

        await model.pick(from: .gallery)
        #expect(model.state == .attached(plusSlashImage))
        #expect(model.hasImage)
        #expect(picker.requested == [.gallery])

        #expect(model.takeImageForSend() == plusSlashImage)
        #expect(model.state == .empty)
        #expect(model.takeImageForSend() == nil, "the same image cannot be sent twice")
    }

    @Test("A cancelled pick returns to empty with no hint")
    func cancelledPick() async {
        let picker = FakeImagePicker()
        picker.result = .success(nil)
        let model = AttachmentModel(picker: picker)
        var hints: [AttachHint] = []
        model.onHint = { hints.append($0) }

        await model.pick(from: .camera)

        #expect(model.state == .empty)
        #expect(hints.isEmpty, "cancelling is not an error")
    }

    @Test("A denied camera is told apart from a failed pick")
    func hints() async {
        let picker = FakeImagePicker()
        let model = AttachmentModel(picker: picker)
        var hints: [AttachHint] = []
        model.onHint = { hints.append($0) }

        picker.result = .failure(ImagePermissionDenied())
        await model.pick(from: .camera)
        #expect(model.state == .empty)
        #expect(hints == [.cameraPermissionDenied])

        picker.result = .failure(FakeSpeechFailure())
        await model.pick(from: .gallery)
        #expect(hints == [.cameraPermissionDenied, .pickFailed])
    }

    @Test("Vision is tri-state: only a known false blocks the attach button")
    func visionTriState() {
        let model = AttachmentModel(picker: FakeImagePicker())
        #expect(model.visionSupported == nil)
        #expect(!model.attachBlockedByVision, "unknown must not gate")

        model.applyVision(true)
        #expect(!model.attachBlockedByVision)

        model.applyVision(false)
        #expect(model.attachBlockedByVision)

        model.applyVision(nil)
        #expect(!model.attachBlockedByVision, "losing the catalogue re-opens the button")
    }

    @Test("reset drops the image and its decoded preview")
    func reset() async {
        let picker = FakeImagePicker()
        picker.result = .success(plusSlashImage)
        let model = AttachmentModel(picker: picker)
        await model.pick(from: .gallery)

        model.reset()
        #expect(model.state == .empty)
        #expect(model.preview == nil)
    }

    @Test("removeImage is the ✕ on the preview")
    func removeImage() async {
        let picker = FakeImagePicker()
        picker.result = .success(plusSlashImage)
        let model = AttachmentModel(picker: picker)
        await model.pick(from: .gallery)

        model.removeImage()
        #expect(model.state == .empty)
    }
}

@MainActor
@Suite("Image wire encoding (spec 08 §13.1)")
struct ComposerImageWireTests {
    @Test("Images are STANDARD base64, not base64url, and carry no data: prefix")
    func standardBase64() {
        let wire = plusSlashImage.wire
        #expect(wire.data == "+/+/", "base64url would spell these bytes -_-_")
        #expect(!wire.data.contains("-"))
        #expect(!wire.data.contains("_"))
        #expect(!wire.data.hasPrefix("data:"))
        #expect(wire.mime == "image/jpeg")
    }

    @Test("An empty images array is omitted from user_message, never sent as []")
    func imagesOmittedWhenEmpty() throws {
        let withImage = UserMessage(id: "m1", text: "look", images: [plusSlashImage.wire])
        let json = try String(data: WireJSON.encode(ClientMessage.userMessage(withImage)), encoding: .utf8)
        #expect(json?.contains("\"images\"") == true)

        let plain = UserMessage(id: "m2", text: "hi", images: [])
        let plainJSON = try String(data: WireJSON.encode(ClientMessage.userMessage(plain)), encoding: .utf8)
        #expect(plainJSON?.contains("\"images\"") == false)
        #expect(
            plainJSON?.contains("streaming_behavior") == false,
            "the key is omitted when not steering, never sent as null"
        )
    }

    @Test("A steering send spells the behaviour exactly once, as \"steer\"")
    func steerOnTheWire() throws {
        let steer = UserMessage(id: "m3", text: "no, tabs", streamingBehavior: .steer)
        let json = try String(data: WireJSON.encode(ClientMessage.userMessage(steer)), encoding: .utf8)
        #expect(json?.contains("\"streaming_behavior\":\"steer\"") == true)
    }
}

@Suite("Image compression policy (spec 08 §8.10)")
struct ImageCompressionPolicyTests {
    @Test("An image under the ceiling is encoded exactly once")
    func singlePass() {
        let policy = ImageCompressionPolicy()
        var calls: [(Int, Int)] = []
        let data = policy.compress { side, quality in
            calls.append((side, quality))
            return Data(count: 100)
        }
        #expect(calls.count == 1)
        #expect(calls[0].0 == 1568)
        #expect(calls[0].1 == 80)
        #expect(data.count == 100)
    }

    @Test("An oversized image shrinks and terminates within the pass budget")
    func iterativeCeiling() {
        let policy = ImageCompressionPolicy()
        var calls: [(side: Int, quality: Int)] = []
        // Always over the ceiling: the loop must stop on the pass budget, not
        // spin forever.
        let data = policy.compress { side, quality in
            calls.append((side, quality))
            return Data(count: policy.ceilingBytes + 1)
        }

        #expect(calls.count == 1 + policy.maxExtraPasses)
        #expect(calls.map(\.quality) == [80, 65, 50, 35])
        #expect(calls.map(\.side) == [1568, 1333, 1133, 963])
        #expect(
            data.count == policy.ceilingBytes + 1,
            "the last encoding is returned — an oversized attachment beats no attachment"
        )
    }

    @Test("Quality never falls below the floor")
    func qualityFloor() {
        let policy = ImageCompressionPolicy(maxSide: 100, quality: 40, ceilingBytes: 1, maxExtraPasses: 5)
        var qualities: [Int] = []
        _ = policy.compress { _, quality in
            qualities.append(quality)
            return Data(count: 999)
        }
        #expect(qualities.allSatisfy { $0 >= 35 })
    }

    @Test("A shrinking image stops as soon as it fits")
    func stopsWhenUnderCeiling() {
        let policy = ImageCompressionPolicy()
        var pass = 0
        _ = policy.compress { _, _ in
            pass += 1
            return Data(count: pass == 1 ? policy.ceilingBytes + 1 : 10)
        }
        #expect(pass == 2)
    }
}

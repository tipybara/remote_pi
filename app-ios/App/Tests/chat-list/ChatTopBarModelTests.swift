import Foundation
import RemotePiProtocol
import XCTest

@testable import RemotePi

/// Spec 08 §8.2 — the fixed top bar's three resolutions: title, device, pill.
@MainActor
final class ChatTopBarModelTests: XCTestCase {

    private let peerKey = PeerID(rawValue: Data(repeating: 7, count: 32))!

    private func record(nickname: String? = nil, sessionName: String? = nil) -> PeerRecord {
        PeerRecord(
            peer: peerKey,
            relayURL: "https://relay.example",
            pairedAt: "2026-08-25T00:00:00Z",
            sessionName: sessionName,
            nickname: nickname
        )
    }

    // MARK: Title chain

    func testTitlePrefersThePublishedRoomName() {
        let model = ChatTopBarModel(hints: .init(title: "hint"))
        model.meta = RoomMeta(roomID: RoomID("r1"), name: "refactor sync", cwd: "/Users/x/proj")
        model.firstUserMessage = "please refactor the sync service"
        XCTAssertEqual(model.resolvedTitle, "refactor sync")
    }

    func testTitleFallsBackToTheCwdBasename() {
        let model = ChatTopBarModel(hints: .init(title: "hint"))
        model.meta = RoomMeta(roomID: RoomID("r1"), cwd: "/Users/x/work/remote_pi")
        XCTAssertEqual(model.resolvedTitle, "remote_pi")
    }

    func testTitleFallsBackToWorkspacePathWhenThereIsNoCwd() {
        let model = ChatTopBarModel()
        model.meta = RoomMeta(roomID: RoomID("r1"), workspacePath: "/srv/agents/api")
        XCTAssertEqual(model.resolvedTitle, "api")
    }

    func testTitleFallsBackToTheFirstUserMessageCappedAt32Characters() {
        let model = ChatTopBarModel(hints: .init(title: "hint"))
        model.firstUserMessage = String(repeating: "a", count: 40)
        XCTAssertEqual(model.resolvedTitle, String(repeating: "a", count: 32))
    }

    /// Newlines in the first message must not smear the one-line bar.
    func testInferredTitleCollapsesWhitespace() {
        XCTAssertEqual(
            ChatTopBarModel.inferredTitle(from: "fix   the\n\nbuild"),
            "fix the build"
        )
        XCTAssertNil(ChatTopBarModel.inferredTitle(from: "   \n "))
        XCTAssertNil(ChatTopBarModel.inferredTitle(from: nil))
    }

    /// The deliberate deviation from `_inferSessionName` (`chat_page.dart:556`):
    /// a transcript with no *user* row must still reach the nav hint instead of
    /// falling straight to the literal "Remote Pi".
    func testTranscriptWithoutAUserMessageStillUsesTheHint() {
        let model = ChatTopBarModel(hints: .init(title: "remote_pi"))
        model.firstUserMessage = nil
        XCTAssertEqual(model.resolvedTitle, "remote_pi")
    }

    func testTitleOfLastResort() {
        XCTAssertEqual(ChatTopBarModel().resolvedTitle, "Remote Pi")
    }

    func testTitleTruncatesToTwentyEightCharactersWithAnEllipsis() {
        let model = ChatTopBarModel()
        model.meta = RoomMeta(roomID: RoomID("r1"), name: String(repeating: "x", count: 40))
        XCTAssertEqual(model.title.count, 28)
        XCTAssertTrue(model.title.hasSuffix("…"))

        model.meta = RoomMeta(roomID: RoomID("r1"), name: String(repeating: "x", count: 28))
        XCTAssertEqual(model.title, String(repeating: "x", count: 28))
    }

    // MARK: Device chain

    func testDeviceLabelChain() {
        let model = ChatTopBarModel(hints: .init(device: "Studio"))
        XCTAssertEqual(model.resolvedDeviceLabel, "Studio", "hint holds the bar until the record loads")

        model.peer = record(nickname: "Work Mac", sessionName: "mac-1")
        XCTAssertEqual(model.resolvedDeviceLabel, "Work Mac")

        model.peer = record(sessionName: "mac-1")
        XCTAssertEqual(model.resolvedDeviceLabel, "mac-1")

        // A loaded record with neither label resolves to the short key — NOT
        // back to the hint: the record is the authority once it exists.
        model.peer = record()
        XCTAssertEqual(model.resolvedDeviceLabel, peerKey.shortDescription)
    }

    func testDeviceLabelOfLastResortIsADash() {
        XCTAssertEqual(ChatTopBarModel().resolvedDeviceLabel, "—")
    }

    func testDeviceLabelTruncatesToTwentyFour() {
        let model = ChatTopBarModel(hints: .init(device: String(repeating: "d", count: 30)))
        XCTAssertEqual(model.deviceLabel.count, 24)
        XCTAssertTrue(model.deviceLabel.hasSuffix("…"))
    }

    // MARK: Status pill

    /// The reason the hint exists: before the app has read a runtime record,
    /// the bar shows what Home showed. Otherwise every chat entry flashes
    /// "offline"/"reconnecting…" on the default runtime.
    func testUnresolvedConnectionTrustsHomesOnlineHint() {
        let model = ChatTopBarModel(hints: .init(online: true))
        model.connectionResolved = false
        model.isRelayConnected = false
        model.isRoomLive = false
        XCTAssertEqual(model.status, .live)
        XCTAssertEqual(model.statusLabel, "online")
    }

    func testResolvedConnectionIgnoresTheHint() {
        let model = ChatTopBarModel(hints: .init(online: true))
        model.connectionResolved = true
        model.isRelayConnected = true
        model.isRoomLive = false
        XCTAssertEqual(model.status, .offline)
        XCTAssertEqual(model.statusLabel, "offline")
    }

    func testReconnectingOutranksLive() {
        let model = ChatTopBarModel()
        model.connectionResolved = true
        model.isRelayConnected = false
        model.isRoomLive = true
        XCTAssertEqual(model.statusLabel, "reconnecting…")
    }

    func testWorkingOutranksEverything() {
        let model = ChatTopBarModel()
        model.connectionResolved = true
        model.isRelayConnected = false
        model.isRoomLive = false
        model.isWorking = true
        XCTAssertEqual(model.status, .working)
        XCTAssertEqual(model.statusLabel, "working…")
    }

    func testOnlineWhenTheRoomIsLiveAndTheSocketIsUp() {
        let model = ChatTopBarModel()
        model.connectionResolved = true
        model.isRelayConnected = true
        model.isRoomLive = true
        XCTAssertEqual(model.statusLabel, "online")
    }

    func testTruncateMatchesTheDartHelper() {
        XCTAssertEqual(ChatTopBarModel.truncate("abc", 5), "abc")
        XCTAssertEqual(ChatTopBarModel.truncate("abcde", 5), "abcde")
        XCTAssertEqual(ChatTopBarModel.truncate("abcdef", 5), "abcd…")
    }
}

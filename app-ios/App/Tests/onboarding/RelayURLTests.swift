import XCTest

@testable import RemotePi

/// Pinned against `app/lib/data/transport/relay_config.dart:67-95`, which is
/// the producer of every rule and both messages.
final class RelayURLTests: XCTestCase {

    func testAcceptsHttpAndHttps() {
        XCTAssertTrue(RelayURL.isValid("https://relay.example.com"))
        XCTAssertTrue(RelayURL.isValid("http://192.168.1.10:8080"))
        XCTAssertTrue(RelayURL.isValid("https://relay.example.com/path"))
        XCTAssertNil(RelayURL.validationMessage("https://relay.example.com"))
    }

    func testRejectsEmpty() {
        XCTAssertFalse(RelayURL.isValid(""))
        XCTAssertEqual(RelayURL.validationMessage(""), RelayURL.invalidGenericMessage)
    }

    /// The ws/wss case gets its own message: the app converts to WebSocket
    /// itself, and a user who types `wss://` is doing the right thing in the
    /// wrong place.
    func testRejectsWebSocketSchemesWithTheSpecificMessage() {
        XCTAssertFalse(RelayURL.isValid("wss://relay.example.com"))
        XCTAssertFalse(RelayURL.isValid("ws://localhost:8080"))
        XCTAssertEqual(
            RelayURL.validationMessage("wss://relay.example.com"),
            RelayURL.invalidSchemeMessage
        )
        XCTAssertEqual(
            RelayURL.validationMessage("ws://localhost:8080"),
            RelayURL.invalidSchemeMessage
        )
    }

    func testRejectsOtherSchemesAndBareHosts() {
        XCTAssertFalse(RelayURL.isValid("relay.example.com"))
        XCTAssertFalse(RelayURL.isValid("ftp://relay.example.com"))
        XCTAssertFalse(RelayURL.isValid("remotepi://pair?x=1"))
        XCTAssertEqual(
            RelayURL.validationMessage("relay.example.com"),
            RelayURL.invalidGenericMessage
        )
    }

    /// `https://` alone parses on Darwin and yields an empty host. A
    /// `URL(string:)`-only check would let it through and the app would try to
    /// open a socket to nothing.
    func testRejectsSchemeWithNoHost() {
        XCTAssertFalse(RelayURL.isValid("https://"))
        XCTAssertFalse(RelayURL.isValid("http:///path"))
    }

    /// A space is not percent-escaped by the user, and `URLComponents` refuses
    /// it — which is the behaviour we want, not a crash.
    func testRejectsMalformedInput() {
        XCTAssertFalse(RelayURL.isValid("https://relay example.com"))
    }
}

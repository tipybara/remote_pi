import Foundation
import XCTest

@testable import RemotePiPairing
@testable import RemotePiProtocol

/// Placeholder for the `RemotePiPairing` work item.
final class RemotePiPairingTests: XCTestCase {
    func testQRPayloadParsesTheURLSafeSpelling() throws {
        let epk = Data(repeating: 0xFB, count: 32)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = Data(repeating: 0x11, count: 16)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let payload = try XCTUnwrap(
            PairingQRPayload.parse("remotepi://pair?t=\(token)&epk=\(epk)&n=backend&rm=abc123def456")
        )
        XCTAssertEqual(payload.peer.rawValue, Data(repeating: 0xFB, count: 32))
        // The QR spells the key URL-safe; the wire spells it standard. The
        // type absorbs the difference so no caller compares the strings.
        XCTAssertTrue(payload.peer.wireValue.contains("+"))
        XCTAssertEqual(payload.room?.rawValue, "abc123def456")
        XCTAssertNil(payload.relayURL, "a QR without `r` uses the configured relay")
    }

    func testMalformedQRIsRejectedOutright() {
        XCTAssertNil(PairingQRPayload.parse("https://example.com"))
        XCTAssertNil(PairingQRPayload.parse("remotepi://pair?t=short&epk=x&n=y"))
    }
}

import Foundation
import XCTest

@testable import RemotePiPairing
@testable import RemotePiProtocol

/// Every fixture here is a string a real `buildQRUri`
/// (`pi-extension/src/pairing/qr.ts:62-89`) can emit — the `+`/`%2B` spellings
/// were produced by running Node's `URLSearchParams` over the same inputs, not
/// written by hand.
final class QRPayloadTests: XCTestCase {
    /// The example in spec 62/04 §3.1, verbatim.
    private let canonical =
        "remotepi://pair?t=Zm9vYmFyYmF6cXV4MTIzNA"
        + "&epk=1sbg3nsX4kRTBmM3XZ_hs4mAujHmbcm7CjfPGkDgpTQ"
        + "&n=remote_pi&rm=019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1"

    func testParsesTheCanonicalQR() throws {
        let payload = try XCTUnwrap(PairingQRPayload.parse(canonical))
        // The token goes back to the Pi verbatim; `!==` there is unforgiving.
        XCTAssertEqual(payload.token, "Zm9vYmFyYmF6cXV4MTIzNA")
        XCTAssertEqual(payload.tokenBytes?.count, 16)
        XCTAssertEqual(payload.peer.rawValue.count, 32)
        XCTAssertEqual(payload.sessionName, "remote_pi")
        XCTAssertEqual(payload.room?.rawValue, "019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1")
        XCTAssertNil(payload.relayURL, "plan 14 removed `r` from the canonical QR")
    }

    /// Trap T2. `URLSearchParams.toString()` writes a space as `+`; Dart's
    /// `Uri.queryParameters` turns it back into a space and
    /// `URLComponents.queryItems` does not. Without the explicit pass the
    /// machine would be named `my+project` everywhere, including in the
    /// nickname sheet and the published membership.
    func testPlusInTheSessionNameIsASpace() throws {
        let raw =
            "remotepi://pair?t=Zm9vYmFyYmF6cXV4MTIzNA"
            + "&epk=1sbg3nsX4kRTBmM3XZ_hs4mAujHmbcm7CjfPGkDgpTQ"
            + "&n=my+project&rm=019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1"
        let payload = try XCTUnwrap(PairingQRPayload.parse(raw))
        XCTAssertEqual(payload.sessionName, "my project")
    }

    /// A key spelled in the standard alphabet survives, because
    /// `URLSearchParams` percent-encodes `+` and `=` — so the `+`→space pass
    /// never sees them. Fixture produced by Node for
    /// `AgcMERYbICUqLzQ5PkNITVJXXGFma3B1en+EiY6TmJ0=`.
    func testStandardAlphabetEPKSurvivesThePlusPass() throws {
        let raw =
            "remotepi://pair?t=Zm9vYmFyYmF6cXV4MTIzNA"
            + "&epk=AgcMERYbICUqLzQ5PkNITVJXXGFma3B1en%2BEiY6TmJ0%3D&n=remote_pi"
        let payload = try XCTUnwrap(PairingQRPayload.parse(raw))
        XCTAssertEqual(
            payload.peer.wireValue,
            "AgcMERYbICUqLzQ5PkNITVJXXGFma3B1en+EiY6TmJ0=",
            "the stored key must round-trip to the relay's canonical spelling"
        )
    }

    /// The same URI is printed for copy-paste (`index.ts:3084-3090`), and a
    /// user dragging it out of a terminal brings whitespace with it. The
    /// Flutter parser does not trim; that is a bug, not a contract.
    func testPastedPayloadWithSurroundingWhitespaceParses() throws {
        let payload = try XCTUnwrap(PairingQRPayload.parse("  \n\(canonical)\t "))
        XCTAssertEqual(payload.sessionName, "remote_pi")
    }

    func testRoomIsOpaque() throws {
        // Trap D3: the doc comments still describe a 12-char base64url digest;
        // since plan 61 the runtime value is a 36-char session UUID. Anything
        // that validated the shape would reject every current Pi.
        let short = canonical.replacingOccurrences(
            of: "019ffb64-3c21-7a55-9b0e-2f7d1c4a88e1",
            with: "Ab3-_9xyzQ12"
        )
        XCTAssertEqual(PairingQRPayload.parse(short)?.room?.rawValue, "Ab3-_9xyzQ12")
    }

    func testRejectsWrongLengthToken() {
        // 15 bytes, not 16 — `qr_scanner.dart:57`.
        let raw =
            "remotepi://pair?t=Zm9vYmFyYmF6cXV4MTIz"
            + "&epk=1sbg3nsX4kRTBmM3XZ_hs4mAujHmbcm7CjfPGkDgpTQ&n=remote_pi"
        XCTAssertNil(PairingQRPayload.parse(raw))
    }

    func testRejectsMixedAlphabetKey() {
        // The relay refuses a string that mixes `+/` with `-_`
        // (`relay/src/identity.rs:15-19`), so accepting it here would only
        // move the failure to a place with less context.
        let raw =
            "remotepi://pair?t=Zm9vYmFyYmF6cXV4MTIzNA"
            + "&epk=1sbg3nsX4kRTBmM3XZ_hs4mAujHmbcm7CjfPGkDgpTQ%2B&n=remote_pi"
        XCTAssertNil(PairingQRPayload.parse(raw))
    }

    func testRejectsForeignSchemeSilently() {
        XCTAssertNil(PairingQRPayload.parse("https://example.com"))
        XCTAssertNil(PairingQRPayload.parse("remotepi://unpair?t=x&epk=y&n=z"))
        XCTAssertNil(PairingQRPayload.parse(""))
    }

    func testMissingNameIsRejected() {
        let raw =
            "remotepi://pair?t=Zm9vYmFyYmF6cXV4MTIzNA"
            + "&epk=1sbg3nsX4kRTBmM3XZ_hs4mAujHmbcm7CjfPGkDgpTQ"
        XCTAssertNil(PairingQRPayload.parse(raw), "`n` is required by qr.ts:85")
    }

    func testLegacyRelayParameterIsCaptured() throws {
        let raw = canonical + "&r=wss%3A%2F%2Frelay.example"
        let payload = try XCTUnwrap(PairingQRPayload.parse(raw))
        XCTAssertEqual(payload.relayURL, "wss://relay.example")
    }
}

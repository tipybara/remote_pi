import Foundation
import XCTest

@testable import RemotePiCrypto
@testable import RemotePiProtocol

/// `EPKEncoding` against the two implementations it has to agree with:
/// `app/lib/data/transport/epk_encoding.dart` (whose own unit test supplies
/// the fixtures below) and `relay/src/identity.rs` (whose test module supplies
/// the rest).
///
/// The acceptance/rejection rows were re-run through `dart:convert` before
/// being pinned, because the Dart helpers inherit their behaviour from that
/// codec rather than stating it.
final class EPKEncodingTests: XCTestCase {

    // MARK: - toStandardB64: the Dart client's own fixtures
    //
    // app/test/transport/epk_encoding_test.dart

    func testConvertsAURLSafeEPKToStandard() {
        let out = EPKEncoding.toStandardB64(WireVectors.dartEPKURLSafe)
        XCTAssertEqual(out, WireVectors.dartEPKStandard)
        XCTAssertFalse(out.contains("_"))
        XCTAssertFalse(out.contains("-"))
        XCTAssertTrue(out.contains("/"))
    }

    func testPassesThroughAnAlreadyStandardEPKUnchanged() {
        XCTAssertEqual(
            EPKEncoding.toStandardB64(WireVectors.dartEPKStandard),
            WireVectors.dartEPKStandard
        )
    }

    func testEmptyStringIsANoOp() {
        XCTAssertEqual(EPKEncoding.toStandardB64(""), "")
        XCTAssertEqual(EPKEncoding.toAppEPK(""), "")
    }

    /// "garbage input returned as-is (defensive)" — the Dart test's own words.
    /// Dropping an unrecognised peer id silently is worse than carrying it:
    /// the value still shows up in a log, and the failure is a routing miss
    /// the user can be told about rather than a peer that vanished.
    func testGarbageInputIsReturnedAsIs() {
        for garbage in [
            "not base64 at all !!",  // Dart: FormatException
            "abcde",  // length % 4 == 1
            "Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=\n",  // trailing newline
            "Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE= ",  // trailing space
            "Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=garbage",
        ] {
            XCTAssertEqual(EPKEncoding.toStandardB64(garbage), garbage)
            XCTAssertEqual(EPKEncoding.toAppEPK(garbage), garbage)
        }
    }

    // MARK: - All four spellings of one key
    //
    // relay/src/identity.rs's `STANDARD_KEY` / `URL_SAFE_KEY` fixtures: 32
    // bytes of 0xfb, chosen there because the encoding exercises `+`, `/`,
    // `-` and `_` in a single key.

    func testAllFourSpellingsNormalizeToTheRelaysRegistryForm() {
        for spelling in [
            WireVectors.relayKeyStandard,
            WireVectors.relayKeyStandardNoPad,
            WireVectors.relayKeyURLSafe,
            WireVectors.relayKeyURLSafeNoPad,
        ] {
            XCTAssertEqual(
                EPKEncoding.toStandardB64(spelling),
                WireVectors.relayKeyStandard,
                "failed to canonicalize \(spelling)"
            )
            XCTAssertEqual(
                EPKEncoding.decodeLenient(spelling),
                Data(repeating: 0xfb, count: 32)
            )
        }
    }

    func testToAppEPKProducesTheUnpaddedURLSafeStorageKey() {
        XCTAssertEqual(
            EPKEncoding.toAppEPK(WireVectors.relayKeyStandard),
            WireVectors.relayKeyURLSafeNoPad
        )
        XCTAssertEqual(
            EPKEncoding.toAppEPK(WireVectors.dartEPKStandard),
            WireVectors.dartEPKURLSafe
        )
        // The padding strip is the point: a stored key with a trailing `=`
        // would not match one built from a scanned QR, and the two would be
        // separate dictionary entries for the same machine.
        XCTAssertFalse(EPKEncoding.toAppEPK(WireVectors.relayKeyStandard).contains("="))
    }

    // MARK: - Idempotence
    //
    // The Flutter ConnectionManager normalizes on every inbound control frame,
    // so these run on already-normalized input constantly.

    func testBothDirectionsAreIdempotentAndInvertEachOther() {
        let inputs = [
            WireVectors.dartEPKStandard,
            WireVectors.dartEPKURLSafe,
            WireVectors.relayKeyStandard,
            WireVectors.relayKeyURLSafeNoPad,
            "not base64 at all !!",
            "",
        ]
        for input in inputs {
            let standard = EPKEncoding.toStandardB64(input)
            XCTAssertEqual(EPKEncoding.toStandardB64(standard), standard, "input: \(input)")

            let app = EPKEncoding.toAppEPK(input)
            XCTAssertEqual(EPKEncoding.toAppEPK(app), app, "input: \(input)")

            // Round trip: storage form → wire form → storage form.
            XCTAssertEqual(EPKEncoding.toAppEPK(EPKEncoding.toStandardB64(app)), app)
        }
    }

    // MARK: - Mixed alphabets: lenient here, rejected by the relay

    /// Dart's Base64 decoder maps `-`/`+` to 62 and `_`/`/` to 63 from one
    /// table with no cross-alphabet check, so a mixed spelling normalizes
    /// cleanly. Verified against `dart:convert` directly.
    ///
    /// This is the one place `EPKEncoding` is deliberately *more* permissive
    /// than `RemotePiProtocol.Base64` / `relay/src/identity.rs`, and the
    /// asymmetry is load-bearing: the relay rejects a mixed `hello.pubkey`
    /// outright and does no normalization at all on the envelope `peer` field
    /// (`registry.rs:254` is a raw-string `HashMap` lookup). A mixed key that
    /// reaches the wire un-normalized is an unexplained `transport_error:
    /// offline`; a mixed key normalized here routes correctly.
    func testMixedAlphabetsNormalizeHereButAreRejectedAsAPeerID() {
        let mixed = "-/v7+/v7+_v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/s="
        XCTAssertEqual(EPKEncoding.toStandardB64(mixed), WireVectors.relayKeyStandard)

        // The strict parser — the one that mirrors what the relay will do to
        // us — refuses the same string.
        XCTAssertNil(PeerID(base64: mixed))
    }

    // MARK: - Non-canonical trailing bits

    /// Foundation's `Data(base64Encoded:)` accepts a final symbol whose unused
    /// low bits are non-zero; Dart's decoder throws and Rust's `base64` engine
    /// errors (`relay/src/identity.rs`,
    /// `canonical_public_key_rejects_noncanonical_trailing_bits`).
    ///
    /// Without the canonicality gate in `decodeLenient`, this input would
    /// "normalize" to a *different* string than the one the sender used, and
    /// the relay — which compares raw strings — would never match it.
    func testNonCanonicalTrailingBitsAreRefusedLikeDartAndRust() {
        // `…+/s=` is canonical for 32 × 0xfb; `…+/t=` sets bits the length
        // cannot carry. Foundation decodes it to the same 32 bytes anyway.
        let nonCanonical = "+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/t="
        XCTAssertNotNil(
            Data(base64Encoded: nonCanonical),
            "precondition: Foundation is lenient here — that is why the gate exists"
        )

        XCTAssertNil(EPKEncoding.decodeLenient(nonCanonical))
        XCTAssertEqual(EPKEncoding.toStandardB64(nonCanonical), nonCanonical)
        XCTAssertEqual(EPKEncoding.toAppEPK(nonCanonical), nonCanonical)
    }

    // MARK: - Agreement with PeerID

    /// `EPKEncoding` and `PeerID` must never disagree about a *well-formed*
    /// key — one is the string-level shim for legacy surfaces, the other is
    /// the type new code carries, and a divergence between them would be
    /// invisible until a peer stopped routing.
    func testAgreesWithPeerIDForEveryWellFormedSpelling() throws {
        for spelling in [
            WireVectors.dartEPKStandard,
            WireVectors.dartEPKURLSafe,
            WireVectors.relayKeyStandard,
            WireVectors.relayKeyStandardNoPad,
            WireVectors.relayKeyURLSafe,
            WireVectors.relayKeyURLSafeNoPad,
            WireVectors.noblePubkeyStandard,
            WireVectors.noblePubkeyURLSafe,
        ] {
            let peer = try XCTUnwrap(PeerID(base64: spelling), "PeerID rejected \(spelling)")
            XCTAssertEqual(EPKEncoding.toStandardB64(spelling), peer.wireValue)
            XCTAssertEqual(EPKEncoding.toAppEPK(spelling), peer.urlSafeValue)
        }
    }
}

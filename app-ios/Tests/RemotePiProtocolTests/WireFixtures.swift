import Foundation
import XCTest

@testable import RemotePiProtocol

/// Shared helpers for the wire-compatibility suites.
///
/// ## Why comparisons go through `NSDictionary`
///
/// A string comparison of encoder output would pin **key order**, which is not
/// part of the wire contract — `JSON.stringify` emits insertion order,
/// `serde_json` emits struct order, and `JSONEncoder` emits its own. Comparing
/// the parsed objects pins exactly what does matter: which keys exist, which
/// are absent, and the value and JSON *type* of each. `NSDictionary`'s equality
/// is deep, and `NSNumber` compares `1` unequal to `true`, so a bool that
/// degraded into a number still fails the test.
enum WireFixtures {
    /// Parses a JSON object literal.
    static func object(_ text: String) throws -> NSDictionary {
        let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(value as? NSDictionary)
    }

    /// Encodes through the production encoder and re-parses.
    static func encoded(_ value: some Encodable) throws -> NSDictionary {
        let data = try WireJSON.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? NSDictionary)
    }

    /// Asserts that `value` serializes to exactly `expected`.
    static func assertEncodes(
        _ value: some Encodable,
        to expected: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try encoded(value), try object(expected), message, file: file, line: line)
    }

    /// A real 32-byte Ed25519 key in the relay's own spelling.
    ///
    /// The archived contract fixtures under `.orchestration/contracts/fixtures`
    /// use short placeholder strings for `peer` (`"RU9rXbR2dEVwM1AyZTM="` is
    /// 14 bytes), which ``PeerID`` correctly refuses — the relay derives its
    /// registry key from a real verifying key and nothing shorter can ever
    /// match. Control-frame tests therefore keep the fixture's *structure* and
    /// substitute a well-formed key here.
    static let peerKeyBytes = Data(repeating: 0xFB, count: 32)
    static let peerKeyStandard = "+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/v7+/s="
    static var peer: PeerID { PeerID(rawValue: peerKeyBytes)! }
}

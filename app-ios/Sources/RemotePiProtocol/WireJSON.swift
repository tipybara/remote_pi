import Foundation

/// Serialization for inner App↔Pi frames.
///
/// ## Why there is no shared `JSONEncoder` instance
///
/// `JSONEncoder` / `JSONDecoder` are not `Sendable`, so a `static let` of one
/// would not compile under strict concurrency and a `nonisolated(unsafe)` one
/// would be a data race the first time two rooms decoded at once. They are
/// cheap to construct; make a fresh one per call.
///
/// ## Why no key strategy
///
/// `.convertFromSnakeCase` is a trap on this protocol. Frame-level keys are
/// snake_case (`in_reply_to`, `tool_call_id`, `notify_type`), but the `ask`
/// envelope mirrors pi-ask's own schema **verbatim** in camelCase —
/// `presentedType`, `requestedType`, `customText`, `optionNotes`
/// (`types.ts:73-85`). The strategy is decoder-wide, so switching it on maps
/// `presentedType` to `presentedtype` and silently nulls all four out: a
/// multi-select question renders as a single-select, and an answer's notes
/// vanish on submit. Every type in this module therefore writes explicit
/// `CodingKeys`.
public enum WireJSON {
    /// An encoder configured the way the wire wants it.
    ///
    /// `.withoutEscapingSlashes` matters for readability of the many paths on
    /// this wire (`workspace_path`, `cwd`, tool args). `\/` is legal JSON and
    /// both peers parse it, so this is cosmetic **here** — but it is not
    /// cosmetic in ``MeshBlob/canonicalBytes()``, where the bytes are signed
    /// and `serde_json` does not escape. Different rule, same mistake.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// Serializes one inner frame.
    ///
    /// No trailing newline. The Dart codec appends one and the channel strips
    /// it again before sending (`codec.dart:5` / `peer_channel.dart:76`), so
    /// nothing on the wire has ever carried it; the Pi emits none either. It
    /// would be harmless — both sides `JSON.parse`, which skips trailing
    /// whitespace — and it would also be one more byte nobody asked for.
    public static func encode(_ value: some Encodable) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try decode(type, from: Data(text.utf8))
    }
}

// MARK: - Envelope bridging

extension Envelope {
    /// Wraps an outbound inner frame for `peer` at `room`.
    ///
    /// The inner JSON is Base64'd with the **standard** alphabet and padding.
    /// URL-safe here is the recurring bug: the relay's `Buffer.from(ct,
    /// "base64")` on the far side is lenient enough to survive it, but nothing
    /// else on this wire is, and a single lenient hop is what let the mistake
    /// live for four plans (`app/lib/data/transport/epk_encoding.dart`).
    public init(peer: PeerID, room: RoomID, message: ClientMessage) throws {
        self.init(peer: peer, room: room, payload: try WireJSON.encode(message))
    }

    /// Wraps a machine-control action. Always addressed at ``RoomID/control``:
    /// the gateway is the only thing that answers these, and sending one to a
    /// chat room gets it silently dropped by a Pi that has no handler for it.
    public init(peer: PeerID, action: ControlAction) throws {
        self.init(peer: peer, room: .control, payload: try action.encoded())
    }

    /// Decodes the inner frame of an inbound envelope.
    ///
    /// Returns `nil` when `ct` is not Base64 or not JSON — matching
    /// `peer_channel.dart:129-133`, which swallows a malformed frame rather
    /// than tearing the socket down. An unrecognised `type` is **not**
    /// malformed: it comes back as ``ServerMessage/unknown(type:raw:)``.
    public func decodeServerMessage() -> ServerMessage? {
        guard let payload else { return nil }
        return try? WireJSON.decode(ServerMessage.self, from: payload)
    }
}

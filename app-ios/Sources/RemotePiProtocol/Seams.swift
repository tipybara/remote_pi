import Foundation

// MARK: - Signing

/// Something that can produce an Ed25519 signature for a known public key.
///
/// Declared here, implemented in `RemotePiCrypto`, consumed by
/// `RemotePiTransport` (the `auth` step of the relay handshake) and by
/// `RemotePiPairing` (`pair_request`, and the `mesh_versions` blob signature).
///
/// Three different keys satisfy this protocol at different moments, and they
/// are **not** interchangeable:
///
/// | Key | Lifetime | Signs |
/// |---|---|---|
/// | Owner-key | Keychain, synchronized across the user's devices | `pair_request`, `mesh_versions` |
/// | App-key | RAM, one pairing attempt | the relay handshake during pairing |
/// | Pi-key | on the Mac, never here | — |
///
/// A conforming type must not expose private key bytes; the seam is
/// deliberately signature-only so a future Secure Enclave backing needs no
/// change above it. (Ed25519 is not Secure-Enclave-backed today — CryptoKit
/// only offers P-256 there — but the shape costs nothing now.)
public protocol Signer: Sendable {
    /// The public half, in the form the relay uses as a peer id.
    var publicKey: PeerID { get }

    /// Signs `message` — the **raw bytes**, never a Base64 or hex rendering of
    /// them. The relay's challenge nonce in particular arrives Base64-encoded
    /// and must be decoded before it reaches here; signing the text is the
    /// classic way to fail `verify_auth` with a valid-looking frame.
    func signature(for message: Data) throws -> Data
}

// MARK: - Key storage

/// Persistent home for this device's long-lived key material.
///
/// Declared here, implemented in `RemotePiCrypto` over the Security framework.
///
/// ## What lives here
///
/// Only the **Owner-key**: one Ed25519 keypair per user, stored with
/// `kSecAttrSynchronizable` so it follows the user to a new phone through
/// iCloud Keychain. That synchronization is the reason a lost phone is
/// survivable while a lost Mac is not — the Pi-key has no equivalent and a new
/// Mac means re-pairing.
///
/// The **App-key** is ephemeral by design and must never be written here.
///
/// ## Representation
///
/// The seam trades in the raw 32-byte Ed25519 **seed** (CryptoKit's
/// `Curve25519.Signing.PrivateKey.rawRepresentation`) rather than a key object,
/// so this module stays free of CryptoKit. Treat the returned `Data` as
/// secret: do not log it, do not copy it into a struct that gets encoded.
public protocol KeyStore: Sendable {
    /// Returns the stored Owner-key, or `nil` when this device has never had
    /// one and iCloud has nothing to hand over.
    ///
    /// Returning `nil` is a normal first-launch outcome, not an error. It must
    /// be distinguishable from a *failure to read* — a Keychain that is
    /// temporarily locked or an entitlement that is missing must `throw`, since
    /// silently treating those as "no key" would mint a second Owner identity
    /// and orphan every existing pairing.
    func loadOwnerKeySeed() async throws -> Data?

    /// Returns the stored seed, generating and persisting one if absent.
    ///
    /// Must be atomic against a concurrent caller: two callers racing on first
    /// launch have to end up with the *same* key, not two.
    func loadOrCreateOwnerKeySeed() async throws -> Data

    /// Overwrites the stored seed — used when adopting a key that arrived from
    /// another device, or on an explicit "restore identity".
    ///
    /// Destructive: the previous identity's pairings become unreachable.
    func storeOwnerKeySeed(_ seed: Data) async throws

    /// Removes the Owner-key from this device.
    ///
    /// Local only. It does **not** revoke anything — a paired Mac keeps
    /// trusting the Owner until a new `mesh_versions` version omits it.
    func deleteOwnerKeySeed() async throws
}

// MARK: - Transport

/// Everything that arrives on a relay connection, in order.
public enum TransportEvent: Sendable {
    /// The handshake completed: `hello` → `challenge` → `auth` all passed and
    /// the relay registered this connection.
    case connected(peer: PeerID)

    /// An App↔Pi frame the relay forwarded. `peer` and `room` name the
    /// **sender** — the relay rewrote them on the way through.
    case envelope(Envelope)

    /// A frame the relay produced itself.
    case control(ControlFrame)

    /// The socket ended. `error` is `nil` for a clean close.
    case disconnected(error: RelayTransportError?)
}

/// Why a relay connection failed.
public enum RelayTransportError: Error, Sendable {
    /// The URL was not a usable `ws://` / `wss://` endpoint.
    case invalidRelayURL(String)
    /// The relay closed before the handshake finished, or the handshake frames
    /// arrived out of order.
    case handshakeFailed(String)
    /// No `challenge` within the relay's 5-second `hello` window.
    case handshakeTimeout
    /// The socket dropped. Reconnect with backoff; this is the common case on
    /// mobile and is not by itself worth surfacing to the user.
    case socketClosed(code: Int, reason: String?)
    /// A frame could not be serialized or parsed.
    case malformedFrame(String)
    /// Sent while not connected.
    case notConnected
    /// The envelope exceeded ``Envelope/maxDecodedPayloadBytes``; the relay
    /// would have dropped it without telling us.
    case payloadTooLarge(estimatedBytes: Int)
    case underlying(any Error)
}

/// The relay WebSocket, as the rest of the app sees it.
///
/// Declared here, implemented in `RemotePiTransport` over
/// `URLSessionWebSocketTask`, consumed by `RemotePiSession` and
/// `RemotePiPairing`. Tests substitute an in-memory conformance — which is the
/// point of the seam.
///
/// ## Contract
///
/// - ``connect(to:as:)`` returns only after the handshake succeeds. Everything
///   before that (`hello`, `challenge`, `auth`) is the implementation's
///   business and never reaches ``events``.
/// - ``events`` yields in arrival order and finishes with
///   ``TransportEvent/disconnected(error:)``. One stream per connection: a
///   reconnect produces a new stream, so consumers must re-subscribe rather
///   than assume the old one resumes.
/// - Sends are per-frame. The relay reads JSONL and never accepts a batch.
/// - A conforming type is an actor or otherwise safe for concurrent sends.
public protocol RelayTransport: Sendable {
    /// Events for the current connection. See the contract above.
    var events: AsyncStream<TransportEvent> { get }

    /// Runs the handshake against `relayURL`, authenticating as `signer`.
    ///
    /// `relayURL` may be given as `http(s)` for user-facing convenience and
    /// must be normalized to `ws(s)` before the socket is opened.
    func connect(to relayURL: URL, as signer: any Signer) async throws

    /// Sends one App↔Pi frame. The implementation must reject a payload over
    /// ``Envelope/maxDecodedPayloadBytes`` locally rather than watch the relay
    /// drop it silently.
    func send(_ envelope: Envelope) async throws

    /// Sends one relay control frame.
    func send(_ frame: ClientControlFrame) async throws

    /// Closes the socket and finishes ``events``. Idempotent.
    func disconnect() async

    /// Points the inbound room demux (and the default outbound room) at
    /// `room`. Pairing must do this *before* `pair_request`: the Pi answers
    /// from the QR's `rm`, which is never ``RoomID/main``, and a mismatch is
    /// dropped silently at the transport layer.
    func setActiveRoom(_ room: RoomID) async
}

extension RelayTransport {
    public func setActiveRoom(_ room: RoomID) async {}
}

// MARK: - Persistence

/// One paired machine, as remembered on this device.
///
/// The `peer` is the machine identity; everything else is a label or a hint.
/// In particular ``lastOpenedRoom`` is **a hint, not connection identity** — a
/// Mac runs many sessions and a single field per pairing cannot express that.
/// Treating it as the key is what made the Flutter client reopen the wrong
/// chat after a cold start (plan 61 Phase 0).
public struct PeerRecord: Hashable, Sendable, Codable {
    public var peer: PeerID
    /// Relay this pairing happened on. Also published in `mesh_versions`.
    public var relayURL: String
    /// ISO-8601. Also the tiebreaker for "which pairing to fall back to" —
    /// never "whichever came first in the dictionary".
    public var pairedAt: String
    /// Session name captured at pair time. Historical; not identity.
    public var sessionName: String?
    /// Local-only label the user typed. Never leaves the device except as the
    /// `nickname` of a `mesh_versions` member.
    public var nickname: String?
    /// `os.hostname()` of the Mac, from `pair_ok`. Distinguishes two paired
    /// machines that share a nickname.
    public var hostname: String?
    /// Host agent name/version from `pair_ok.harness`.
    public var harnessName: String?
    public var harnessVersion: String?
    /// Last chat the user had open on this machine. A **hint** for restoring
    /// the UI, nothing more.
    public var lastOpenedRoom: RoomID?

    public init(
        peer: PeerID,
        relayURL: String,
        pairedAt: String,
        sessionName: String? = nil,
        nickname: String? = nil,
        hostname: String? = nil,
        harnessName: String? = nil,
        harnessVersion: String? = nil,
        lastOpenedRoom: RoomID? = nil
    ) {
        self.peer = peer
        self.relayURL = relayURL
        self.pairedAt = pairedAt
        self.sessionName = sessionName
        self.nickname = nickname
        self.hostname = hostname
        self.harnessName = harnessName
        self.harnessVersion = harnessVersion
        self.lastOpenedRoom = lastOpenedRoom
    }
}

/// Who produced a persisted transcript row.
public enum StoredMessageRole: String, Hashable, Sendable, Codable {
    /// A `user_message` — including the echo of one this device sent. The echo
    /// is the source of truth: every paired device renders the same timeline
    /// regardless of who typed, so a locally-composed bubble is provisional
    /// until its echo arrives.
    case user
    /// An `agent_message` / the accumulation of `agent_chunk` deltas.
    case agent
    /// A `tool_request` / `tool_result` pair, or a `compaction` marker —
    /// anything the UI renders as an event rather than as speech.
    case event
}

/// One row of a persisted conversation.
///
/// Deliberately lossy compared to the wire: this is what survives a relaunch,
/// not a transcript of every frame.
public struct StoredMessage: Hashable, Sendable, Codable, Identifiable {
    /// The wire `id` where there is one (`user_message.id`) or
    /// `in_reply_to` for agent output. Stable across the echo, so a
    /// provisional local bubble can be reconciled with its echo instead of
    /// duplicated.
    public var id: String
    public var role: StoredMessageRole
    public var text: String
    /// Milliseconds since epoch.
    public var timestamp: Int64
    /// Inline image attachments, base64 exactly as they rode the wire (no
    /// `data:` prefix). Only ever present on a `user` row.
    public var images: [WireImage]

    public init(
        id: String,
        role: StoredMessageRole,
        text: String,
        timestamp: Int64,
        images: [WireImage] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.images = images
    }
}

/// One inline image on a `user_message`.
///
/// `data` is base64 of the compressed bytes **without** a `data:` URI prefix;
/// `mime` maps to the SDK's `mimeType`. It rides a second Base64 inside the
/// envelope's `ct`, so budget roughly 1.78× the raw JPEG against
/// ``Envelope/maxDecodedPayloadBytes``.
public struct WireImage: Hashable, Sendable, Codable {
    public var data: String
    public var mime: String

    public init(data: String, mime: String) {
        self.data = data
        self.mime = mime
    }
}

/// On-device persistence.
///
/// Declared here, implemented in `RemotePiStore`, consumed by
/// `RemotePiSession` and the UI.
///
/// ## The one rule
///
/// Everything session-scoped is keyed by ``SessionKey`` — the machine **and**
/// the room. Never by display name, never by workspace path, never by position
/// in a list, and never by room id alone (it is only unique within a machine).
/// Every "the sessions jump around" bug in the Flutter client traces back to
/// breaking that rule somewhere.
public protocol SessionStore: Sendable {
    // Paired machines.

    func loadPeers() async throws -> [PeerRecord]
    func savePeer(_ record: PeerRecord) async throws
    func deletePeer(_ peer: PeerID) async throws

    // Room catalogue, so Home can render before the relay has announced
    // anything — including the offline case, where it never will.

    func loadRooms(for peer: PeerID) async throws -> [RoomMeta]
    func saveRooms(_ rooms: [RoomMeta], for peer: PeerID) async throws

    // Transcripts.

    /// Most recent `limit` rows, oldest-first.
    func loadMessages(for session: SessionKey, limit: Int) async throws -> [StoredMessage]
    func appendMessage(_ message: StoredMessage, for session: SessionKey) async throws
    /// Replaces the transcript wholesale — what a `session_history` re-sync
    /// produces.
    func replaceMessages(_ messages: [StoredMessage], for session: SessionKey) async throws
    /// Drops one session's transcript. Used when the machine reports the
    /// session gone, never as a side effect of a rename.
    func deleteMessages(for session: SessionKey) async throws

    // UI pointers.

    /// The session the user last had open. Restored in full on cold start:
    /// restoring only the peer and defaulting the room to `main` is what
    /// reopened the wrong chat.
    func loadSelectedSession() async throws -> SessionKey?
    func saveSelectedSession(_ session: SessionKey?) async throws
}

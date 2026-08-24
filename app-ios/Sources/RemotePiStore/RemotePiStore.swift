import Foundation
import RemotePiProtocol

/// On-disk persistence for peers, rooms, transcripts and UI pointers.
///
/// ## Layout
///
/// ```text
/// <AppSupport>/RemotePi/remotepi.sqlite3      the store (WAL)
/// <AppSupport>/RemotePi/blobs/<sha256>.bin    image bytes, content-addressed
/// ```
///
/// The scaffold sketched one JSON file per concern plus one transcript file per
/// session. Spec 07 §4.1 argues that shape down and it is right: files-per-
/// session is what the Hive design already was, and it is the source of three
/// of its traps — box names get case-folded (T7), the set of boxes cannot be
/// enumerated so orphaned conversations cannot be found (T11), and no
/// cross-session query is possible without opening every file, which is why
/// `sessions_index` was invented and then never read (spec §1.5). It also
/// cannot do a tail read: `watchMessages` materialises every row in the box on
/// listen, and one row can be megabytes of base64 image (T8).
///
/// One relational file answers all of that, and `libsqlite3` ships in the SDK,
/// so it costs no dependency.
///
/// ## Keying
///
/// Everything session-scoped is keyed by ``SessionKey`` — machine **and** room
/// — and the schema enforces it: `UNIQUE (machine_pk, session_id)`, with no
/// unique index on `session_id` alone. A room id is only unique within one
/// machine (`pi-extension/src/rooms.ts:92-120`).
///
/// The machine is stored as **32 raw bytes**, never as a string: Trap T2's
/// entire bug class is "which Base64 spelling is this", and there is no
/// spelling here to get wrong.
///
/// ## What a rename must not do
///
/// Nothing here. A rename is a metadata patch: `room_id == session_id` from
/// plan 61 on, so the row does not move, no file is renamed, and no transcript
/// is touched. ``SQLiteSessionStore/applyRoomMetaPatch(_:for:)`` only ever
/// writes `display_name` / `name_rev`, and only when the revision is strictly
/// greater. If a change to this module ever makes a rename touch a message
/// row, the change is wrong.
public typealias FileSessionStore = SQLiteSessionStore

/// Failures the store reports.
public enum StoreError: Error, Sendable, Hashable {
    case notImplemented(String)
    /// A stored file did not parse. Prefer surfacing this over silently
    /// starting from empty — an empty peer list looks exactly like "the user
    /// has never paired", and the UI would offer to pair again.
    case corrupt(path: String)
    /// The operation is not allowed for this target — e.g. a transcript on the
    /// machine control room. See ``StoreError/controlRoom(_:)``.
    case rejected(String)
}

import Foundation

/// The on-disk schema, straight out of spec 07 §4.2, plus the columns the
/// ``SessionStore`` seam needs that the spec's sketch left out.
///
/// Deviations from the spec text, all deliberate:
///
/// * `machine.paired_at` is **TEXT**, not epoch-ms. ``PeerRecord/pairedAt`` is
///   an ISO-8601 *string* on the seam and is compared as a tiebreaker; parsing
///   it to milliseconds and back would not round-trip the exact string the rest
///   of the app already stores.
/// * `machine.unpaired_at` exists so unpairing does **not** delete the row.
///   Trap T11: nothing may delete a user's conversations as a side effect of
///   unpairing, but the `ON DELETE CASCADE` from `session` to `machine` would
///   do exactly that. Unpairing marks; only an explicit purge deletes.
/// * `machine.provisional` marks a row created because a frame arrived before
///   the pairing record was written. Such a row is not a pairing — it has no
///   relay URL — so `loadPeers` hides it, but it still anchors the transcript.
/// * `session` carries `model` / `thinking` / `cwd` so ``RoomMeta`` survives a
///   relaunch for an offline Home. It does **not** carry `working` or
///   `started_at`: spec §4.3 — persisting either reports stale state, which is
///   the exact bug the Hive `runtime` box was wiped at boot to avoid.
/// * `message.role` may also be `'divider'`, a local-only row with no wire
///   counterpart. It marks "the Pi restarted here" so history above the
///   boundary can be kept instead of deleted (Trap T1, rule 3).
enum Schema {
    /// Bumped only for a real migration. `user_version` is checked on open.
    static let version: Int64 = 1

    /// Pragmas that must be set on **every** connection (they are per-connection,
    /// not stored in the file — except `journal_mode`, which is persistent).
    static let pragmas = """
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;
        PRAGMA synchronous = NORMAL;
        """

    static let ddl = """
        -- ── machines ───────────────────────────────────────────────────────
        -- The epk as 32 RAW BYTES. This is the whole fix for Trap T2: an
        -- encoding cannot be wrong if there is no encoding. base64 exists only
        -- at the transport edge (standard+padded) and in filenames (url-safe).
        CREATE TABLE IF NOT EXISTS machine (
          machine_pk       INTEGER PRIMARY KEY,
          epk              BLOB NOT NULL UNIQUE CHECK (length(epk) = 32),
          relay_url        TEXT NOT NULL DEFAULT '',
          paired_at        TEXT NOT NULL DEFAULT '',
          session_name     TEXT,
          nickname         TEXT,
          hostname         TEXT,
          harness_name     TEXT,
          harness_version  TEXT,
          last_opened_room TEXT,
          provisional      INTEGER NOT NULL DEFAULT 0,
          unpaired_at      INTEGER
        );

        -- ── sessions ───────────────────────────────────────────────────────
        CREATE TABLE IF NOT EXISTS session (
          session_pk           INTEGER PRIMARY KEY,
          machine_pk           INTEGER NOT NULL
                               REFERENCES machine(machine_pk) ON DELETE CASCADE,
          session_id           TEXT NOT NULL,   -- == room_id, opaque, CASE-SENSITIVE
          workspace_id         TEXT,
          workspace_path       TEXT,
          cwd                  TEXT,
          display_name         TEXT,
          name_rev             INTEGER,
          role                 TEXT,            -- 'control' for ctrl; NULL for chat
          mode                 TEXT,
          model                TEXT,
          thinking             TEXT,
          session_started_at   INTEGER,
          last_message_at      INTEGER,
          last_message_preview TEXT,
          next_seq             INTEGER NOT NULL DEFAULT 0,
          -- The (epk, session_id) scope from pi-extension/src/rooms.ts:92-120,
          -- enforced by the engine instead of by discipline. There is NO unique
          -- index on session_id alone: two machines may emit the same id.
          UNIQUE (machine_pk, session_id)
        );
        CREATE INDEX IF NOT EXISTS session_by_recency
          ON session(last_message_at DESC);

        -- ── messages ───────────────────────────────────────────────────────
        CREATE TABLE IF NOT EXISTS message (
          session_pk    INTEGER NOT NULL
                        REFERENCES session(session_pk) ON DELETE CASCADE,
          seq           INTEGER NOT NULL,   -- position, NOT identity (Trap T6)
          role          TEXT NOT NULL,
          msg_id        TEXT NOT NULL,
          text          TEXT NOT NULL DEFAULT '',
          ts            INTEGER NOT NULL,   -- epoch ms
          pending       INTEGER NOT NULL DEFAULT 0,
          steering      INTEGER NOT NULL DEFAULT 0,
          tokens_before INTEGER,
          in_reply_to   TEXT,
          tool_call_id  TEXT,
          tool_name     TEXT,
          tool_status   TEXT,
          tool_args     BLOB,               -- raw JSON bytes, opaque
          tool_result   BLOB,               -- raw JSON bytes, opaque
          tool_error    TEXT,
          PRIMARY KEY (session_pk, seq)
        ) WITHOUT ROWID;

        -- Trap T5: identity is (role, msg_id), never msg_id. A user row and the
        -- assistant row answering it routinely share an id (agent_message is
        -- keyed by in_reply_to).
        CREATE UNIQUE INDEX IF NOT EXISTS message_identity
          ON message(session_pk, role, msg_id);
        CREATE INDEX IF NOT EXISTS message_pending
          ON message(session_pk, pending) WHERE pending = 1;

        -- ── attachments (Trap T8: bytes out of the row) ─────────────────────
        CREATE TABLE IF NOT EXISTS attachment (
          attachment_pk INTEGER PRIMARY KEY,
          session_pk    INTEGER NOT NULL,
          seq           INTEGER NOT NULL,
          ordinal       INTEGER NOT NULL DEFAULT 0,
          mime          TEXT NOT NULL,
          sha256        BLOB NOT NULL,
          byte_len      INTEGER NOT NULL,
          file_name     TEXT NOT NULL,      -- relative to the blob directory
          -- 1: file holds the decoded bytes, re-encode to base64 on read.
          -- 0: the wire string did not decode as base64 and the file holds it
          --    verbatim as UTF-8. Dropping an image the user actually sent is
          --    worse than storing a string we do not understand.
          canonical     INTEGER NOT NULL DEFAULT 1,
          -- ON UPDATE CASCADE is load-bearing: a preserved pending row is
          -- re-keyed to the tail after a history sync, and without the cascade
          -- that UPDATE fails the constraint (the child still points at the old
          -- seq) or, worse, orphans the image.
          FOREIGN KEY (session_pk, seq)
            REFERENCES message(session_pk, seq)
            ON DELETE CASCADE ON UPDATE CASCADE
        );
        CREATE INDEX IF NOT EXISTS attachment_by_message
          ON attachment(session_pk, seq);

        -- ── app state (UI pointers) ────────────────────────────────────────
        CREATE TABLE IF NOT EXISTS app_state (
          key   TEXT PRIMARY KEY,
          value TEXT
        );
        """
}

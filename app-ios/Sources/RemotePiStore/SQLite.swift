import Foundation
import SQLite3

// A hand-rolled, deliberately small wrapper over the SQLite C API.
//
// Why the C API and not Core Data / GRDB: spec 07 §4.1. The write model is a
// serialized command log with explicit conflict rules, not an object graph, and
// the package forbids third-party dependencies. `libsqlite3` ships in the SDK,
// so `import SQLite3` costs nothing at the package level.
//
// Nothing in here is `Sendable`: a connection handle and its statements are
// owned by exactly one actor (`SQLiteSessionStore`) and must never escape it.
// That single-owner rule is what gives us spec §2.1's "one serial writer".

/// `SQLITE_TRANSIENT` is a macro the Swift importer cannot see, so it is
/// re-created here. Passing `nil` (i.e. `SQLITE_STATIC`) instead would tell
/// SQLite the bytes outlive the call — they do not, because Swift `String` and
/// `Data` buffers are temporary — and it would read freed memory.
nonisolated(unsafe) let sqliteTransient = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)

/// One value in a bound parameter list or a result row.
enum SQLValue: Hashable {
    case null
    case int(Int64)
    case text(String)
    case blob(Data)

    var intValue: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var blobValue: Data? {
        if case .blob(let value) = self { return value }
        return nil
    }

    var boolValue: Bool { (intValue ?? 0) != 0 }

    static func bool(_ value: Bool) -> SQLValue { .int(value ? 1 : 0) }

    static func optionalText(_ value: String?) -> SQLValue {
        value.map { .text($0) } ?? .null
    }

    static func optionalInt(_ value: Int64?) -> SQLValue {
        value.map { .int($0) } ?? .null
    }

    static func optionalBlob(_ value: Data?) -> SQLValue {
        value.map { .blob($0) } ?? .null
    }
}

/// One result row, addressed by column name.
///
/// Name-addressed rather than index-addressed on purpose: every `SELECT` in
/// this module lists its columns explicitly, and a positional read silently
/// reads the wrong column the moment somebody reorders that list.
struct SQLRow {
    private let values: [String: SQLValue]

    init(values: [String: SQLValue]) { self.values = values }

    subscript(column: String) -> SQLValue { values[column] ?? .null }

    func int(_ column: String) -> Int64? { self[column].intValue }
    func text(_ column: String) -> String? { self[column].textValue }
    func blob(_ column: String) -> Data? { self[column].blobValue }
    func bool(_ column: String) -> Bool { self[column].boolValue }
}

/// Errors coming out of the SQLite layer itself.
struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    let sql: String?

    var description: String {
        "SQLite error \(code): \(message)" + (sql.map { " — while running: \($0)" } ?? "")
    }
}

/// A single database connection.
final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        // Deliberately NOT SQLITE_OPEN_NOFOLLOW: SQLite rejects a symlink
        // anywhere in the *path* under that flag, and every real path here has
        // one — an iOS container lives under /var/mobile, and /var is a symlink
        // to /private/var (same on macOS for NSTemporaryDirectory). It fails
        // with SQLITE_CANTOPEN before the file is ever created.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: rc, message: message, sql: nil)
        }
        handle = db
        // A busy timeout matters even for a single-writer app: iOS may still be
        // finishing a WAL checkpoint from the previous launch when we open.
        sqlite3_busy_timeout(db, 3_000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    /// Runs one or more statements with no parameters and no results.
    func execute(_ sql: String) throws {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed", sql: sql) }
        var errorPointer: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard rc == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(errorPointer)
            throw SQLiteError(code: rc, message: message, sql: sql)
        }
    }

    /// Runs a parameterized statement that returns nothing.
    @discardableResult
    func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        _ = try step(sql, parameters, collectRows: false)
        return Int(sqlite3_changes(handle))
    }

    /// Runs a parameterized query and materializes every row.
    ///
    /// Materializing is fine here because every query in this module is either
    /// bounded by `LIMIT` or bounded by the number of paired machines. A "read
    /// the whole transcript into memory" query is exactly what spec 07 Trap T8
    /// says not to do, so there is no streaming cursor to tempt anyone.
    func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [SQLRow] {
        try step(sql, parameters, collectRows: true)
    }

    func queryOne(_ sql: String, _ parameters: [SQLValue] = []) throws -> SQLRow? {
        try query(sql, parameters).first
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Wraps `body` in `BEGIN IMMEDIATE` / `COMMIT`.
    ///
    /// `IMMEDIATE`, not deferred: the transaction takes the write lock up front,
    /// so an upgrade cannot fail halfway through with `SQLITE_BUSY` and leave a
    /// half-applied history reconciliation behind.
    ///
    /// `body` is deliberately **not** `async`. Holding a write transaction open
    /// across a suspension point is the one way this store can be killed by the
    /// OS mid-transaction while blocking every other write (spec §4.5).
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            // Best-effort: if the ROLLBACK itself fails the connection is
            // already unusable, and the original error is the interesting one.
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Truncating checkpoint — call when the app goes to the background so the
    /// `-wal` file does not survive suspension holding committed pages.
    func checkpointTruncate() {
        guard let handle else { return }
        sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    // MARK: - Internals

    private func step(
        _ sql: String,
        _ parameters: [SQLValue],
        collectRows: Bool
    ) throws -> [SQLRow] {
        guard let handle else { throw SQLiteError(code: SQLITE_MISUSE, message: "closed", sql: sql) }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            throw SQLiteError(code: prepared, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
        }
        defer { sqlite3_finalize(statement) }

        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch parameter {
            case .null:
                rc = sqlite3_bind_null(statement, index)
            case .int(let value):
                rc = sqlite3_bind_int64(statement, index, value)
            case .text(let value):
                rc = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .blob(let value):
                // An empty Data has no base address; bind a zero-length blob
                // explicitly rather than passing a null pointer, which SQLite
                // would store as NULL and break a `NOT NULL` column.
                if value.isEmpty {
                    rc = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    rc = value.withUnsafeBytes { raw in
                        sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), sqliteTransient)
                    }
                }
            }
            guard rc == SQLITE_OK else {
                throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
            }
        }

        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
            }
            guard collectRows else { continue }
            rows.append(Self.readRow(statement))
        }
        return rows
    }

    private static func readRow(_ statement: OpaquePointer) -> SQLRow {
        var values: [String: SQLValue] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, index))
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER:
                values[name] = .int(sqlite3_column_int64(statement, index))
            case SQLITE_TEXT:
                values[name] = .text(String(cString: sqlite3_column_text(statement, index)))
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, index))
                if count == 0 {
                    values[name] = .blob(Data())
                } else if let pointer = sqlite3_column_blob(statement, index) {
                    values[name] = .blob(Data(bytes: pointer, count: count))
                } else {
                    values[name] = .blob(Data())
                }
            case SQLITE_FLOAT:
                // No column in this schema is a REAL. If one ever appears,
                // truncating to Int64 silently would be worse than storing the
                // rounded value visibly, so make it an integer here and let a
                // test catch it.
                values[name] = .int(Int64(sqlite3_column_double(statement, index)))
            default:
                values[name] = .null
            }
        }
        return SQLRow(values: values)
    }
}

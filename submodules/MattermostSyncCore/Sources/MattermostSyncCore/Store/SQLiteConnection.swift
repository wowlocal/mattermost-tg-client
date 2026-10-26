import Foundation
// Telegram-iOS links its vendored SQLCipher (`//submodules/sqlcipher:sqlcipher`, module `sqlcipher`).
// Linking the system libsqlite3 next to it would clash on the `sqlite3_*` symbols, so the system
// module is only used when SQLCipher isn't available (SwiftPM builds and tests). Only the C API
// subset both provide is used here.
#if canImport(sqlcipher)
import sqlcipher
#else
import SQLite3
#endif

/// `SQLITE_TRANSIENT` is a macro (a destructor pointer of -1) and isn't imported into Swift.
private var transientDestructor: sqlite3_destructor_type {
    return unsafeBitCast(-1 as Int, to: sqlite3_destructor_type.self)
}

/// A value bound to a statement parameter.
enum SQLiteValue {
    case integer(Int64)
    case text(String)
    case null

    static func optionalText(_ value: String?) -> SQLiteValue {
        return value.map { .text($0) } ?? .null
    }

    static func bool(_ value: Bool) -> SQLiteValue {
        return .integer(value ? 1 : 0)
    }
}

/// The current result row of a statement. Only valid inside the row callback.
struct SQLiteRow {
    fileprivate let statement: OpaquePointer

    func int64(_ column: Int32) -> Int64 {
        return sqlite3_column_int64(statement, column)
    }

    func bool(_ column: Int32) -> Bool {
        return sqlite3_column_int64(statement, column) != 0
    }

    func isNull(_ column: Int32) -> Bool {
        return sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    func string(_ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else {
            return ""
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    func optionalString(_ column: Int32) -> String? {
        return isNull(column) ? nil : string(column)
    }
}

/// One SQLite connection with a cache of prepared statements. Not thread-safe: the owner
/// serializes every call.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(path: String, busyTimeoutMilliseconds: Int32) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let database = database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            if let database = database {
                sqlite3_close_v2(database)
            }
            throw MattermostSyncStoreError.sqlite(code: result, message: "open \(path): \(message)")
        }
        handle = database
        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)
    }

    deinit {
        close()
    }

    var isOpen: Bool {
        return handle != nil
    }

    func close() {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        statements.removeAll()
        if let handle = handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    /// Rows changed by the most recent INSERT, UPDATE or DELETE.
    var changes: Int {
        return handle.map { Int(sqlite3_changes($0)) } ?? 0
    }

    var lastInsertRowId: Int64 {
        return handle.map { sqlite3_last_insert_rowid($0) } ?? 0
    }

    /// Runs a script of one or more statements without parameters, ignoring result rows.
    func executeScript(_ sql: String) throws {
        guard let handle = handle else {
            throw MattermostSyncStoreError.closed
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw MattermostSyncStoreError.sqlite(code: result, message: "\(message) in script")
        }
    }

    /// Runs one statement, calling `row` for every result row.
    func query(_ sql: String, _ bindings: [SQLiteValue] = [], row: (SQLiteRow) throws -> Void) throws {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .integer(integer):
                result = sqlite3_bind_int64(statement, index, integer)
            case let .text(text):
                // `withCString` gives a valid pointer even for "", which must bind as an empty
                // string (a nil pointer would bind NULL).
                result = text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), transientDestructor) }
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            if result != SQLITE_OK {
                throw error(result, sql: sql)
            }
        }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                try row(SQLiteRow(statement: statement))
            } else if result == SQLITE_DONE {
                return
            } else {
                throw error(result, sql: sql)
            }
        }
    }

    /// Runs one statement and ignores result rows.
    func execute(_ sql: String, _ bindings: [SQLiteValue] = []) throws {
        try query(sql, bindings) { _ in }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] {
            return statement
        }
        guard let handle = handle else {
            throw MattermostSyncStoreError.closed
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let prepared = statement else {
            sqlite3_finalize(statement)
            throw error(result, sql: sql)
        }
        statements[sql] = prepared
        return prepared
    }

    private func error(_ code: Int32, sql: String) -> MattermostSyncStoreError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
        return .sqlite(code: code, message: "\(message) in \(sql)")
    }
}

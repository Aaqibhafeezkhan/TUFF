import Foundation
import SQLite3

enum AppSQLiteError: Error, Equatable, CustomStringConvertible {
    case open(String)
    case statement(String)

    var description: String {
        switch self {
        case .open(let message): "The local search index could not be opened: \(message)"
        case .statement(let message): "The local search index failed: \(message)"
        }
    }
}

/// The few SQLite operations the local search index needs. Not thread-safe;
/// the index serializes every use behind its own lock.
final class AppSQLiteDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(db)
            throw AppSQLiteError.open(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2_000)
    }

    deinit { sqlite3_close(handle) }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw AppSQLiteError.statement(message)
        }
    }

    enum Value: Equatable {
        case text(String)
        case integer(Int64)
        case real(Double)
        case null
    }

    /// Runs `sql` with `bindings` and returns every row.
    @discardableResult
    func query(_ sql: String, _ bindings: [Value] = []) throws -> [[Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw AppSQLiteError.statement(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case .integer(let number): sqlite3_bind_int64(statement, position, number)
            case .real(let number): sqlite3_bind_double(statement, position, number)
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        var rows: [[Value]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw AppSQLiteError.statement(String(cString: sqlite3_errmsg(handle)))
            }
            var row: [Value] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_NULL: row.append(.null)
                default:
                    row.append(.text(sqlite3_column_text(statement, column)
                        .map { String(cString: $0) } ?? ""))
                }
            }
            rows.append(row)
        }
        return rows
    }
}

extension AppSQLiteDatabase.Value {
    var string: String? { if case .text(let value) = self { return value }; return nil }
    var int: Int? { if case .integer(let value) = self { return Int(value) }; return nil }
    var double: Double? {
        switch self {
        case .real(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }
}

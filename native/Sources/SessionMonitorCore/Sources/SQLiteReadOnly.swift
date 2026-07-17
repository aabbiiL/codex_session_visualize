import CSQLite3
import Foundation

final class SQLiteReadOnly {
    static let openFlags: Int32 =
        SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
    static let busyTimeoutMilliseconds: Int32 = 100

    private let database: OpaquePointer

    init(databaseURL: URL) throws {
        var openedDatabase: OpaquePointer?
        let openCode = sqlite3_open_v2(
            Self.uri(for: databaseURL),
            &openedDatabase,
            Self.openFlags,
            nil
        )

        guard openCode == SQLITE_OK, let openedDatabase else {
            let error = SQLiteReadOnlyError(
                code: openCode,
                message: Self.errorMessage(from: openedDatabase)
            )
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            throw error
        }

        let timeoutCode = sqlite3_busy_timeout(
            openedDatabase,
            Self.busyTimeoutMilliseconds
        )
        guard timeoutCode == SQLITE_OK else {
            let error = SQLiteReadOnlyError(
                code: timeoutCode,
                message: Self.errorMessage(from: openedDatabase)
            )
            sqlite3_close_v2(openedDatabase)
            throw error
        }

        database = openedDatabase
    }

    deinit {
        sqlite3_close_v2(database)
    }

    static func uri(for databaseURL: URL) -> String {
        "file:\(databaseURL.standardizedFileURL.path)?mode=ro"
    }

    func columns(in table: String) throws -> Set<String> {
        let escapedTable = table.replacingOccurrences(of: "\"", with: "\"\"")
        let statement = try prepare("PRAGMA table_info(\"\(escapedTable)\");")
        var columns = Set<String>()

        while try statement.step() {
            if let name = statement.text(at: 1) {
                columns.insert(name)
            }
        }

        return columns
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var preparedStatement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(
            database,
            sql,
            -1,
            &preparedStatement,
            nil
        )

        guard prepareCode == SQLITE_OK, let preparedStatement else {
            if let preparedStatement {
                sqlite3_finalize(preparedStatement)
            }
            throw makeError(code: prepareCode)
        }

        return SQLiteStatement(
            database: database,
            statement: preparedStatement
        )
    }

    private func makeError(code: Int32) -> SQLiteReadOnlyError {
        SQLiteReadOnlyError(
            code: code,
            message: Self.errorMessage(from: database)
        )
    }

    private static func errorMessage(from database: OpaquePointer?) -> String {
        guard let database, let message = sqlite3_errmsg(database) else {
            return "SQLite error"
        }
        return String(cString: message)
    }
}

final class SQLiteStatement {
    private let database: OpaquePointer
    private var statement: OpaquePointer?

    init(database: OpaquePointer, statement: OpaquePointer) {
        self.database = database
        self.statement = statement
    }

    deinit {
        if let statement {
            sqlite3_finalize(statement)
        }
    }

    func step() throws -> Bool {
        guard let statement else { return false }

        let stepCode = sqlite3_step(statement)
        switch stepCode {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SQLiteReadOnlyError(
                code: stepCode,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
    }

    func text(at index: Int32) -> String? {
        guard
            let statement,
            sqlite3_column_type(statement, index) != SQLITE_NULL,
            let value = sqlite3_column_text(statement, index)
        else {
            return nil
        }

        return String(
            cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self)
        )
    }

    func int64(at index: Int32) -> Int64? {
        guard
            let statement,
            sqlite3_column_type(statement, index) != SQLITE_NULL
        else {
            return nil
        }

        return sqlite3_column_int64(statement, index)
    }
}

struct SQLiteReadOnlyError: Error {
    let code: Int32
    let message: String

    var primaryCode: Int32 {
        code & 0xFF
    }

    var isLocked: Bool {
        primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED
    }
}

func sourceIssue(for error: Error, databaseURL: URL) -> SourceIssue {
    guard let sqliteError = error as? SQLiteReadOnlyError else {
        return .databaseError(path: databaseURL.path, code: SQLITE_ERROR)
    }

    if sqliteError.isLocked {
        return .lockedDatabase(path: databaseURL.path)
    }

    if sqliteError.primaryCode == SQLITE_CANTOPEN,
       !FileManager.default.fileExists(atPath: databaseURL.path) {
        return .missingFile(path: databaseURL.path)
    }

    return .databaseError(path: databaseURL.path, code: sqliteError.primaryCode)
}

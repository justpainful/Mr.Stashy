import Foundation
import SQLite3

private final class SQLiteConnection: @unchecked Sendable {
    var handle: OpaquePointer?

    deinit {
        if let handle { sqlite3_close(handle) }
    }
}

/// Metadata-only SQLite index. Archive manifests and media remain in the file store so a
/// post can always be reopened without depending on a database blob.
actor LibraryDatabase {
    private let connectionBox = SQLiteConnection()

    private var connection: OpaquePointer? { connectionBox.handle }

    func migrate(at databaseURL: URL) throws {
        if connection == nil {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard sqlite3_open_v2(databaseURL.path, &connectionBox.handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                throw LibraryDatabaseError.openFailed(message: errorMessage)
            }
            try execute("PRAGMA foreign_keys = ON;")
            try execute("PRAGMA journal_mode = WAL;")
        }

        try execute("CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY);")
        let applied = try appliedVersions()
        if !applied.contains(1) {
            try execute("""
            CREATE TABLE archives (
                archive_id TEXT PRIMARY KEY NOT NULL,
                saved_at REAL NOT NULL,
                platform TEXT NOT NULL,
                author TEXT NOT NULL,
                summary_json BLOB NOT NULL
            );
            """)
            try execute("CREATE INDEX archives_saved_at ON archives(saved_at DESC);")
            try execute("INSERT INTO schema_migrations(version) VALUES (1);")
        }
        if !applied.contains(2) {
            try execute("CREATE VIRTUAL TABLE archive_search USING fts5(archive_id UNINDEXED, author, text);")
            try execute("INSERT INTO schema_migrations(version) VALUES (2);")
        }
    }

    func upsert(_ summary: ArchivedPostSummary) throws {
        let data = try JSONEncoder.stashy.encode(summary)
        try withStatement("""
        INSERT INTO archives(archive_id, saved_at, platform, author, summary_json)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(archive_id) DO UPDATE SET
            saved_at = excluded.saved_at,
            platform = excluded.platform,
            author = excluded.author,
            summary_json = excluded.summary_json;
        """) { statement in
            bind(summary.id.uuidString, to: 1, statement: statement)
            sqlite3_bind_double(statement, 2, summary.savedAt.timeIntervalSinceReferenceDate)
            bind(summary.platform.rawValue, to: 3, statement: statement)
            bind(summary.author, to: 4, statement: statement)
            let result: Int32 = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 5, bytes.baseAddress, Int32(data.count), sqliteTransient)
            }
            guard result == SQLITE_OK else {
                throw LibraryDatabaseError.statementFailed(message: errorMessage)
            }
            try step(statement)
        }
        try updateSearchIndex(summary)
    }

    func summaries(matching query: String? = nil) throws -> [ArchivedPostSummary] {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sql: String
        if trimmed.isEmpty {
            sql = "SELECT summary_json FROM archives ORDER BY saved_at DESC;"
        } else {
            sql = """
            SELECT archives.summary_json FROM archive_search
            INNER JOIN archives ON archives.archive_id = archive_search.archive_id
            WHERE archive_search MATCH ?
            ORDER BY archives.saved_at DESC;
            """
        }
        return try withStatement(sql) { statement in
            if !trimmed.isEmpty { bind(ftsQuery(trimmed), to: 1, statement: statement) }
            var result: [ArchivedPostSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
                let length = Int(sqlite3_column_bytes(statement, 0))
                result.append(try JSONDecoder.stashy.decode(ArchivedPostSummary.self, from: Data(bytes: bytes, count: length)))
            }
            return result
        }
    }

    func remove(archiveID: UUID) throws {
        try withStatement("DELETE FROM archive_search WHERE archive_id = ?;") { statement in
            bind(archiveID.uuidString, to: 1, statement: statement)
            try step(statement)
        }
        try withStatement("DELETE FROM archives WHERE archive_id = ?;") { statement in
            bind(archiveID.uuidString, to: 1, statement: statement)
            try step(statement)
        }
    }

    private func updateSearchIndex(_ summary: ArchivedPostSummary) throws {
        try withStatement("DELETE FROM archive_search WHERE archive_id = ?;") { statement in
            bind(summary.id.uuidString, to: 1, statement: statement)
            try step(statement)
        }
        try withStatement("INSERT INTO archive_search(archive_id, author, text) VALUES (?, ?, ?);") { statement in
            bind(summary.id.uuidString, to: 1, statement: statement)
            bind(summary.author, to: 2, statement: statement)
            bind(summary.text, to: 3, statement: statement)
            try step(statement)
        }
    }

    private func appliedVersions() throws -> Set<Int> {
        try withStatement("SELECT version FROM schema_migrations;") { statement in
            var versions = Set<Int>()
            while sqlite3_step(statement) == SQLITE_ROW { versions.insert(Int(sqlite3_column_int(statement, 0))) }
            return versions
        }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw LibraryDatabaseError.statementFailed(message: error.map { String(cString: $0) } ?? errorMessage)
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LibraryDatabaseError.statementFailed(message: errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw LibraryDatabaseError.statementFailed(message: errorMessage)
        }
    }

    private func bind(_ value: String, to index: Int32, statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func ftsQuery(_ input: String) -> String {
        input.split(whereSeparator: { $0.isWhitespace }).map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " AND ")
    }

    private var errorMessage: String {
        guard let connection, let message = sqlite3_errmsg(connection) else { return "Unknown SQLite error" }
        return String(cString: message)
    }
}

enum LibraryDatabaseError: LocalizedError {
    case openFailed(message: String)
    case statementFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Could not open Stashy library database: \(message)"
        case .statementFailed(let message): "Could not update Stashy library database: \(message)"
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

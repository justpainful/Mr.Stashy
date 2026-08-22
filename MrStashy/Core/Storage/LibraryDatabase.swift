import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A search index over archive summaries. The manifests on disk are the truth; this only
/// makes the library fast to list and search, and is rebuilt from them when missing.
final class LibraryDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    init(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw StashyError.storage
        }
        try execute("PRAGMA journal_mode = WAL;")
        try execute("""
        CREATE TABLE IF NOT EXISTS archives (
            id TEXT PRIMARY KEY NOT NULL,
            saved_at REAL NOT NULL,
            platform TEXT NOT NULL,
            summary BLOB NOT NULL
        );
        """)
        try execute("CREATE INDEX IF NOT EXISTS archives_saved_at ON archives(saved_at DESC);")
        try execute("CREATE VIRTUAL TABLE IF NOT EXISTS archive_text USING fts5(id UNINDEXED, body);")
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func upsert(_ summary: ArchiveSummary) throws {
        let data = try JSONEncoder.stashy.encode(summary)
        try locked {
            try statement("INSERT OR REPLACE INTO archives(id, saved_at, platform, summary) VALUES (?, ?, ?, ?);") { statement in
                sqlite3_bind_text(statement, 1, summary.id.uuidString, -1, sqliteTransient)
                sqlite3_bind_double(statement, 2, summary.savedAt.timeIntervalSinceReferenceDate)
                sqlite3_bind_text(statement, 3, summary.platform.rawValue, -1, sqliteTransient)
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(data.count), sqliteTransient) }
                try step(statement)
            }
            try statement("DELETE FROM archive_text WHERE id = ?;") { statement in
                sqlite3_bind_text(statement, 1, summary.id.uuidString, -1, sqliteTransient)
                try step(statement)
            }
            let body = [summary.authorName, summary.authorHandle ?? "", summary.title ?? "", summary.text, summary.platform.rawValue].joined(separator: " ")
            try statement("INSERT INTO archive_text(id, body) VALUES (?, ?);") { statement in
                sqlite3_bind_text(statement, 1, summary.id.uuidString, -1, sqliteTransient)
                sqlite3_bind_text(statement, 2, body, -1, sqliteTransient)
                try step(statement)
            }
        }
    }

    func remove(_ id: UUID) throws {
        try locked {
            for sql in ["DELETE FROM archive_text WHERE id = ?;", "DELETE FROM archives WHERE id = ?;"] {
                try statement(sql) { statement in
                    sqlite3_bind_text(statement, 1, id.uuidString, -1, sqliteTransient)
                    try step(statement)
                }
            }
        }
    }

    func all() throws -> [ArchiveSummary] {
        try locked {
            try statement("SELECT summary FROM archives ORDER BY saved_at DESC;") { statement in
                try read(statement)
            }
        }
    }

    func search(_ query: String) throws -> [ArchiveSummary] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }
        guard !terms.isEmpty else { return try all() }
        return try locked {
            try statement("SELECT archives.summary FROM archive_text JOIN archives ON archives.id = archive_text.id WHERE archive_text MATCH ? ORDER BY archives.saved_at DESC;") { statement in
                sqlite3_bind_text(statement, 1, terms.joined(separator: " AND "), -1, sqliteTransient)
                return try read(statement)
            }
        }
    }

    func count() -> Int {
        (try? locked {
            try statement("SELECT COUNT(*) FROM archives;") { statement in
                sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
            }
        }) ?? 0
    }

    // MARK: Plumbing

    private func read(_ statement: OpaquePointer) throws -> [ArchiveSummary] {
        var rows: [ArchiveSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 0))
            if let summary = try? JSONDecoder.stashy.decode(ArchiveSummary.self, from: Data(bytes: bytes, count: length)) { rows.append(summary) }
        }
        return rows
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw StashyError.storage }
    }

    private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw StashyError.storage }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StashyError.storage }
    }
}

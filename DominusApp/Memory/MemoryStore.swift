import Foundation
import SQLite3

/// SQLite-backed store for conversation memory.
/// Uses the system-provided libsqlite3 — no third-party package needed.
@MainActor
final class MemoryStore {

    static let shared = MemoryStore()

    private var db: OpaquePointer?

    private var dbURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dominus_memory.sqlite")
    }

    init() {
        openDatabase()
        createSchema()
    }

    // MARK: - Schema

    private func openDatabase() {
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            print("❌ MemoryStore: cannot open database at \(dbURL.path)")
            return
        }
        // WAL mode for better concurrent read performance
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
    }

    private func createSchema() {
        let ddl = """
        CREATE TABLE IF NOT EXISTS memories (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id TEXT NOT NULL,
            content       TEXT NOT NULL,
            embedding     BLOB,
            created_at    REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_conv ON memories(conversation_id);
        CREATE INDEX IF NOT EXISTS idx_time ON memories(created_at DESC);
        """
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, ddl, nil, nil, &err) != SQLITE_OK, let e = err {
            print("❌ MemoryStore schema error:", String(cString: e))
            sqlite3_free(err)
        }
    }

    // MARK: - Insert

    func insert(conversationID: UUID, content: String, embedding: [Float]?) {
        let sql = """
        INSERT INTO memories (conversation_id, content, embedding, created_at)
        VALUES (?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let idStr = conversationID.uuidString
        _ = idStr.withCString   { sqlite3_bind_text(stmt, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        _ = content.withCString { sqlite3_bind_text(stmt, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }

        if let vec = embedding {
            let data = MemoryEmbedder.shared.vectorToData(vec)
            _ = data.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(data.count),
                                  unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)

        if sqlite3_step(stmt) != SQLITE_DONE {
            print("❌ MemoryStore: insert failed")
        }
    }

    // MARK: - Fetch

    struct MemoryRow {
        let id: Int64
        let conversationID: String
        let content: String
        let embedding: [Float]?
        let createdAt: Double
    }

    /// Fetches all rows — used by retriever for similarity scoring.
    func fetchAll() -> [MemoryRow] {
        let sql = "SELECT id, conversation_id, content, embedding, created_at FROM memories ORDER BY created_at DESC LIMIT 2000;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [MemoryRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id         = sqlite3_column_int64(stmt, 0)
            let convID     = String(cString: sqlite3_column_text(stmt, 1))
            let content    = String(cString: sqlite3_column_text(stmt, 2))
            let createdAt  = sqlite3_column_double(stmt, 4)

            var embedding: [Float]?
            if sqlite3_column_type(stmt, 3) != SQLITE_NULL,
               let blob = sqlite3_column_blob(stmt, 3) {
                let bytes = Int(sqlite3_column_bytes(stmt, 3))
                embedding = MemoryEmbedder.shared.dataToVector(Data(bytes: blob, count: bytes))
            }

            rows.append(MemoryRow(id: id, conversationID: convID,
                                  content: content, embedding: embedding,
                                  createdAt: createdAt))
        }
        return rows
    }

    // MARK: - Cleanup

    /// Keep at most `limit` rows per conversation to prevent unbounded growth.
    func pruneIfNeeded(conversationID: UUID, keepLatest limit: Int = 200) {
        let sql = """
        DELETE FROM memories
        WHERE conversation_id = ?
          AND id NOT IN (
            SELECT id FROM memories
            WHERE conversation_id = ?
            ORDER BY created_at DESC
            LIMIT ?
          );
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let idStr = conversationID.uuidString
        idStr.withCString { ptr in
            _ = sqlite3_bind_text(stmt, 1, ptr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            _ = sqlite3_bind_text(stmt, 2, ptr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_int(stmt, 3, Int32(limit))
        sqlite3_step(stmt)
    }

    deinit {
        sqlite3_close(db)
    }
}

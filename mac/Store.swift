// Chat storage in ~/.orchard/orchard.db, shared with the Orchard web UI.
// Same schema as store.go.
import Foundation
import SQLite3

struct Chat: Identifiable, Hashable {
    var id: Int64
    var title: String
    var systemPrompt: String
}

struct ChatMessage: Identifiable, Hashable {
    var id: Int64
    var role: String  // "user" | "assistant"
    var content: String
}

let defaultSystemPrompt = "You are a helpful assistant. Be concise."
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Store {
    private var db: OpaquePointer?

    init() throws {
        let dir =
            ProcessInfo.processInfo.environment["ORCHARD_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".orchard")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("orchard.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw StoreError(message: "can't open \(path)")
        }
        try exec(
            """
            PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
            CREATE TABLE IF NOT EXISTS chats (
                id INTEGER PRIMARY KEY, title TEXT NOT NULL DEFAULT '',
                system_prompt TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY,
                chat_id INTEGER NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
                role TEXT NOT NULL, content TEXT NOT NULL, created_at TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS messages_chat ON messages(chat_id, id);
            """)
    }

    deinit { sqlite3_close(db) }

    struct StoreError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Runs a statement with bound text/int args, calling row for each result row.
    @discardableResult
    private func query(_ sql: String, _ args: [Any] = [], row: ((OpaquePointer) -> Void)? = nil)
        throws -> Int64
    {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            switch a {
            case let v as Int64: sqlite3_bind_int64(stmt, Int32(i + 1), v)
            case let v as String: sqlite3_bind_text(stmt, Int32(i + 1), v, -1, SQLITE_TRANSIENT)
            default: break
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                row?(stmt!)
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw StoreError(message: String(cString: sqlite3_errmsg(db)))
            }
        }
        return sqlite3_last_insert_rowid(db)
    }

    private func text(_ s: OpaquePointer, _ i: Int32) -> String {
        sqlite3_column_text(s, i).map { String(cString: $0) } ?? ""
    }

    private var now: String { ISO8601DateFormatter().string(from: Date()) }

    func chats() throws -> [Chat] {
        var out: [Chat] = []
        try query("SELECT id, title, system_prompt FROM chats ORDER BY id DESC") { s in
            out.append(
                Chat(
                    id: sqlite3_column_int64(s, 0), title: self.text(s, 1),
                    systemPrompt: self.text(s, 2)))
        }
        return out
    }

    func createChat() throws -> Chat {
        let id = try query(
            "INSERT INTO chats (title, system_prompt, created_at) VALUES (?, ?, ?)",
            ["New chat", defaultSystemPrompt, now])
        return Chat(id: id, title: "New chat", systemPrompt: defaultSystemPrompt)
    }

    func update(_ c: Chat) throws {
        try query(
            "UPDATE chats SET title = ?, system_prompt = ? WHERE id = ?",
            [c.title, c.systemPrompt, c.id])
    }

    func delete(_ id: Int64) throws {
        try query("DELETE FROM chats WHERE id = ?", [id])
    }

    func messages(_ chatID: Int64) throws -> [ChatMessage] {
        var out: [ChatMessage] = []
        try query("SELECT id, role, content FROM messages WHERE chat_id = ? ORDER BY id", [chatID])
        { s in
            out.append(
                ChatMessage(
                    id: sqlite3_column_int64(s, 0), role: self.text(s, 1), content: self.text(s, 2))
            )
        }
        return out
    }

    @discardableResult
    func add(_ chatID: Int64, role: String, content: String) throws -> ChatMessage {
        let id = try query(
            "INSERT INTO messages (chat_id, role, content, created_at) VALUES (?, ?, ?, ?)",
            [chatID, role, content, now])
        return ChatMessage(id: id, role: role, content: content)
    }
}

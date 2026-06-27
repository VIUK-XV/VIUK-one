/*
仕様:
- 役割: AI Studio の会話本文と承認済みメモリーだけを索引して検索する。
- 主な型: `AIConversationSearchStore`.
- 編集ポイント: 検索対象、索引方式、件数制限を変えるときに触る。
*/
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class AIConversationSearchStore {
    static let shared = AIConversationSearchStore()

    struct SearchResult: Hashable {
        let entryID: String
        let scope: String
        let sourceType: String
        let threadID: String?
        let role: String?
        let visibleText: String
        let createdAt: Date
        let score: Double
    }

    struct IndexedThread {
        let scope: String
        let threadID: String
        let messages: [AICoachService.ChatMessage]
    }

    private let queue = DispatchQueue(label: "viuk.ai.conversation-search-store")
    private var db: OpaquePointer?

    private init() {}

    func rebuildIndex(
        scope: String,
        threads: [IndexedThread],
        approvedMemories: [String]
    ) {
        queue.sync {
            guard openDatabaseIfNeeded() else { return }
            guard beginTransaction() else { return }

            defer {
                _ = execute(sql: "COMMIT;")
            }

            _ = execute(sql: "DELETE FROM conversation_search;")

            for thread in threads {
                for (index, message) in thread.messages.enumerated() {
                    let visibleText = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !visibleText.isEmpty else { continue }
                    let role = message.role == .user ? "user" : "assistant"
                    let entryID = "message:\(thread.threadID):\(index)"
                    let searchText = normalizedSearchText(from: visibleText)
                    insertEntry(
                        entryID: entryID,
                        scope: thread.scope,
                        sourceType: "message",
                        threadID: thread.threadID,
                        role: role,
                        visibleText: visibleText,
                        searchText: searchText,
                        createdAt: message.timestamp.timeIntervalSince1970
                    )
                }
            }

            for (index, memory) in approvedMemories.enumerated() {
                let visibleText = memory.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !visibleText.isEmpty else { continue }
                let entryID = "memory:\(index)"
                let searchText = normalizedSearchText(from: visibleText)
                insertEntry(
                    entryID: entryID,
                    scope: scope,
                    sourceType: "approved_memory",
                    threadID: nil,
                    role: nil,
                    visibleText: visibleText,
                    searchText: searchText,
                    createdAt: Date().timeIntervalSince1970
                )
            }
        }
    }

    func search(queries: [String], limit: Int, scope: String) -> [SearchResult] {
        queue.sync {
            guard openDatabaseIfNeeded() else { return [] }

            var merged: [String: SearchResult] = [:]
            for query in queries {
                for result in searchSingleQuery(query: query, limit: limit, scope: scope) {
                    if let current = merged[result.entryID] {
                        if result.score < current.score {
                            merged[result.entryID] = result
                        }
                    } else {
                        merged[result.entryID] = result
                    }
                }
            }

            return merged.values
                .sorted {
                    if $0.score == $1.score {
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.score < $1.score
                }
                .prefix(limit)
                .map { $0 }
        }
    }

    private func searchSingleQuery(query: String, limit: Int, scope: String) -> [SearchResult] {
        let matchQuery = normalizedMatchQuery(from: query)
        guard !matchQuery.isEmpty else { return [] }

        let sql = """
        SELECT entry_id, scope, source_type, thread_id, role, visible_text, created_at, bm25(conversation_search)
        FROM conversation_search
        WHERE conversation_search MATCH ? AND scope = ?
        ORDER BY bm25(conversation_search), created_at DESC
        LIMIT ?;
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, NSString(string: matchQuery).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, NSString(string: scope).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var results: [SearchResult] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let entryID = stringValue(from: statement, column: 0) ?? UUID().uuidString
            let resultScope = stringValue(from: statement, column: 1) ?? scope
            let sourceType = stringValue(from: statement, column: 2) ?? "message"
            let threadID = stringValue(from: statement, column: 3)
            let role = stringValue(from: statement, column: 4)
            let visibleText = stringValue(from: statement, column: 5) ?? ""
            let createdAtValue = sqlite3_column_double(statement, 6)
            let score = sqlite3_column_double(statement, 7)

            results.append(
                SearchResult(
                    entryID: entryID,
                    scope: resultScope,
                    sourceType: sourceType,
                    threadID: threadID,
                    role: role,
                    visibleText: visibleText,
                    createdAt: Date(timeIntervalSince1970: createdAtValue),
                    score: score
                )
            )
        }

        return results
    }

    private func openDatabaseIfNeeded() -> Bool {
        if db != nil {
            return true
        }

        guard let databaseURL = databaseURL() else { return false }
        let directoryURL = databaseURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return false
        }

        _ = execute(sql: "DROP TABLE IF EXISTS conversation_search;")

        let createTable = """
        CREATE VIRTUAL TABLE IF NOT EXISTS conversation_search
        USING fts5(
            entry_id UNINDEXED,
            scope UNINDEXED,
            source_type UNINDEXED,
            thread_id UNINDEXED,
            role UNINDEXED,
            visible_text UNINDEXED,
            search_text,
            created_at UNINDEXED,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """

        return execute(sql: createTable)
    }

    private func beginTransaction() -> Bool {
        execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
    }

    private func execute(sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func insertEntry(
        entryID: String,
        scope: String,
        sourceType: String,
        threadID: String?,
        role: String?,
        visibleText: String,
        searchText: String,
        createdAt: TimeInterval
    ) {
        let sql = """
        INSERT INTO conversation_search
        (entry_id, scope, source_type, thread_id, role, visible_text, search_text, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, NSString(string: entryID).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, NSString(string: scope).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, NSString(string: sourceType).utf8String, -1, SQLITE_TRANSIENT)
        bindOptionalText(threadID, to: statement, column: 4)
        bindOptionalText(role, to: statement, column: 5)
        sqlite3_bind_text(statement, 6, NSString(string: visibleText).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 7, NSString(string: searchText).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 8, createdAt)
        sqlite3_step(statement)
    }

    private func bindOptionalText(_ value: String?, to statement: OpaquePointer?, column: Int32) {
        if let value, !value.isEmpty {
            sqlite3_bind_text(statement, column, NSString(string: value).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, column)
        }
    }

    private func stringValue(from statement: OpaquePointer?, column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }

    private func normalizedSearchText(from text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedMatchQuery(from query: String) -> String {
        let tokens = query
            .replacingOccurrences(of: "“", with: " ")
            .replacingOccurrences(of: "”", with: " ")
            .replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: "　", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return "" }
        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
            .joined(separator: " OR ")
    }

    private func databaseURL() -> URL? {
        guard let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return baseURL
            .appendingPathComponent("VIUK One", isDirectory: true)
            .appendingPathComponent("AIStudio", isDirectory: true)
            .appendingPathComponent("conversation-index.sqlite", isDirectory: false)
    }
}

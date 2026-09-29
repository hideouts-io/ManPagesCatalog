import Foundation
import SQLite3

struct CachedManual: Sendable {
    let id: String
    let fingerprint: String
    let description: String
    let diagnostic: String
}

/// The application-owned on-disk index. Original sources and the legacy PDF catalog are never modified.
actor ManualSearchIndex {
    private var database: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "No database handle"
            if let handle { sqlite3_close(handle) }
            throw ManualToolError(message: "Cannot open search index \(url.path): \(detail)")
        }
        database = handle
        let status = sqlite3_exec(handle, "CREATE VIRTUAL TABLE IF NOT EXISTS manuals_v3 USING fts5(id UNINDEXED, fingerprint UNINDEXED, description, body, diagnostic UNINDEXED);", nil, nil, nil)
        guard status == SQLITE_OK else {
            let detail = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            database = nil
            throw ManualToolError(message: "Cannot initialize FTS5 index: \(detail)")
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    func metadata() throws -> [CachedManual] {
        let statement = try prepare("SELECT id, fingerprint, description, diagnostic FROM manuals_v3", values: [])
        defer { sqlite3_finalize(statement) }
        var result: [CachedManual] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append(CachedManual(id: column(statement, index: 0), fingerprint: column(statement, index: 1), description: column(statement, index: 2), diagnostic: column(statement, index: 3)))
            status = sqlite3_step(statement)
        }
        try check(status: status, operation: "read metadata")
        return result
    }

    func store(page: ManualPage, text: String, description: String, diagnostic: String) throws {
        try execute("BEGIN IMMEDIATE", values: [])
        do {
            try execute("DELETE FROM manuals_v3 WHERE id = ?", values: [page.id])
            try execute("INSERT INTO manuals_v3(id,fingerprint,description,body,diagnostic) VALUES(?,?,?,?,?)", values: [page.id, page.fingerprint, description, text, diagnostic])
            try execute("COMMIT", values: [])
        } catch {
            try execute("ROLLBACK", values: [])
            throw error
        }
    }

    func matchingIDs(query: String) throws -> Set<String> {
        let tokens = query.split(whereSeparator: \.isWhitespace).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        guard !tokens.isEmpty else { return [] }
        let statement = try prepare("SELECT id FROM manuals_v3 WHERE manuals_v3 MATCH ? ORDER BY bm25(manuals_v3)", values: [tokens.joined(separator: " AND ")])
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.insert(column(statement, index: 0))
            status = sqlite3_step(statement)
        }
        try check(status: status, operation: "search full text")
        return result
    }

    private func execute(_ sql: String, values: [String]) throws {
        let statement = try prepare(sql, values: values)
        defer { sqlite3_finalize(statement) }
        try check(status: sqlite3_step(statement), operation: sql)
    }

    private func prepare(_ sql: String, values: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw indexError(operation: sql)
        }
        for (index, value) in values.enumerated() {
            let result = value.withCString { pointer in
                sqlite3_bind_text(statement, Int32(index + 1), pointer, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            if result != SQLITE_OK { sqlite3_finalize(statement); throw indexError(operation: "bind query parameter") }
        }
        return statement
    }

    private func column(_ statement: OpaquePointer, index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func check(status: Int32, operation: String) throws {
        guard status == SQLITE_DONE else { throw indexError(operation: operation) }
    }

    private func indexError(operation: String) -> ManualToolError {
        ManualToolError(message: "Search index failed to \(operation): \(String(cString: sqlite3_errmsg(database)))")
    }
}

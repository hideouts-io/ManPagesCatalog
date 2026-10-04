import Foundation
import SQLite3

struct CachedManual: Sendable {
    let id: String
    let fingerprint: String
    let description: String
    let diagnostic: String
}

struct ManualIndexRecord: Sendable {
    let id: String
    let fingerprint: String
    let body: String
    let description: String
    let diagnostic: String
}

struct ManualIndexError: LocalizedError, Sendable {
    let path: String
    let extendedCode: Int32
    let operation: String
    let detail: String
    let rollbackDetail: String?

    var errorDescription: String? {
        let rollback = rollbackDetail.map { " Rollback also failed: \($0)." } ?? ""
        return "Search index \(path) could not \(operation) (SQLite \(extendedCode)): \(detail).\(rollback) Check free storage and write access to the app's library folder."
    }
}

/// The app-owned index uses a keyed rowid table without changing retained FTS5 content.
actor ManualSearchIndex {
    private let database: OpaquePointer
    private let path: String

    init(url: URL) throws {
        path = url.path
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { throw ManualIndexError(path: url.path, extendedCode: SQLITE_CANTOPEN, operation: "create its library folder", detail: error.localizedDescription, rollbackDetail: nil) }
        var handle: OpaquePointer?
        let status = sqlite3_open(url.path, &handle)
        guard status == SQLITE_OK, let handle else {
            let failure = manualIndexError(database: handle, path: url.path, operation: "open database", status: status)
            if let handle { sqlite3_close(handle) }
            throw failure
        }
        do {
            guard sqlite3_db_readonly(handle, "main") == 0 else {
                throw ManualIndexError(path: url.path, extendedCode: SQLITE_READONLY, operation: "open writable database", detail: "The database is read-only", rollbackDetail: nil)
            }
            try checkManualIndexStatus(sqlite3_extended_result_codes(handle, 1), expected: SQLITE_OK, database: handle, path: url.path, operation: "enable extended errors")
            try checkManualIndexStatus(sqlite3_busy_timeout(handle, 1_000), expected: SQLITE_OK, database: handle, path: url.path, operation: "set the 1,000 ms lock deadline")
            try initializeManualIndex(database: handle, path: url.path)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        database = handle
    }

    deinit { sqlite3_close(database) }

    func metadata() throws -> [CachedManual] {
        try Task.checkCancellation()
        let statement = try prepareManualIndexSQL(database: database, path: path, sql: "SELECT id, fingerprint, description, diagnostic FROM manuals_v3")
        defer { sqlite3_finalize(statement) }
        var result: [CachedManual] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            result.append(CachedManual(id: try column(statement, index: 0), fingerprint: try column(statement, index: 1), description: try column(statement, index: 2), diagnostic: try column(statement, index: 3)))
            status = sqlite3_step(statement)
        }
        try checkManualIndexStatus(status, expected: SQLITE_DONE, database: database, path: path, operation: "read metadata")
        return result
    }

    func store(page: ManualPage, text: String, description: String, diagnostic: String) throws {
        try store(records: [ManualIndexRecord(id: page.id, fingerprint: page.fingerprint, body: text, description: description, diagnostic: diagnostic)])
    }

    /// At most four already formatted manuals become durable in one atomic transaction.
    func store(records: [ManualIndexRecord]) throws {
        try Task.checkCancellation()
        guard !records.isEmpty, records.count <= 4, Set(records.map(\.id)).count == records.count else {
            throw ManualIndexError(path: path, extendedCode: SQLITE_MISUSE, operation: "store a bounded batch", detail: "Expected 1–4 records with distinct manual IDs; received \(records.count)", rollbackDetail: nil)
        }
        try executeManualIndexSQL(database: database, path: path, sql: "BEGIN IMMEDIATE")
        do {
            let lookup = try prepareManualIndexSQL(database: database, path: path, sql: "SELECT manual_rowid FROM manuals_rowids_v1 WHERE id = ?")
            defer { sqlite3_finalize(lookup) }
            let remove = try prepareManualIndexSQL(database: database, path: path, sql: "DELETE FROM manuals_v3 WHERE rowid = ?")
            defer { sqlite3_finalize(remove) }
            let insert = try prepareManualIndexSQL(database: database, path: path, sql: "INSERT INTO manuals_v3(id,fingerprint,description,body,diagnostic) VALUES(?,?,?,?,?)")
            defer { sqlite3_finalize(insert) }
            let mapping = try prepareManualIndexSQL(database: database, path: path, sql: "INSERT INTO manuals_rowids_v1(id,manual_rowid) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET manual_rowid=excluded.manual_rowid")
            defer { sqlite3_finalize(mapping) }
            for record in records {
                try Task.checkCancellation()
                try bind(record.id, to: lookup, index: 1)
                let status = sqlite3_step(lookup)
                if status == SQLITE_ROW {
                    let rowid = sqlite3_column_int64(lookup, 0)
                    try checkManualIndexStatus(sqlite3_step(lookup), expected: SQLITE_DONE, database: database, path: path, operation: "finish keyed manual lookup")
                    try checkManualIndexStatus(sqlite3_bind_int64(remove, 1, rowid), expected: SQLITE_OK, database: database, path: path, operation: "bind existing manual rowid")
                    try checkManualIndexStatus(sqlite3_step(remove), expected: SQLITE_DONE, database: database, path: path, operation: "replace existing manual by rowid")
                    try reset(remove)
                } else {
                    try checkManualIndexStatus(status, expected: SQLITE_DONE, database: database, path: path, operation: "look up manual ID")
                }
                try reset(lookup)
                for (offset, value) in [record.id, record.fingerprint, record.description, record.body, record.diagnostic].enumerated() {
                    try bind(value, to: insert, index: Int32(offset + 1))
                }
                try checkManualIndexStatus(sqlite3_step(insert), expected: SQLITE_DONE, database: database, path: path, operation: "insert formatted manual")
                let rowid = sqlite3_last_insert_rowid(database)
                try reset(insert)
                try bind(record.id, to: mapping, index: 1)
                try checkManualIndexStatus(sqlite3_bind_int64(mapping, 2, rowid), expected: SQLITE_OK, database: database, path: path, operation: "bind new manual rowid")
                try checkManualIndexStatus(sqlite3_step(mapping), expected: SQLITE_DONE, database: database, path: path, operation: "save keyed manual lookup")
                try reset(mapping)
            }
            try Task.checkCancellation()
            try executeManualIndexSQL(database: database, path: path, sql: "COMMIT")
        } catch {
            throw rollbackManualIndex(database: database, path: path, original: error)
        }
    }

    func matchingIDs(query: String) throws -> Set<String> {
        try Task.checkCancellation()
        let tokens = query.split(whereSeparator: \.isWhitespace).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        guard !tokens.isEmpty else { return [] }
        let statement = try prepareManualIndexSQL(database: database, path: path, sql: "SELECT id FROM manuals_v3 WHERE manuals_v3 MATCH ?")
        defer { sqlite3_finalize(statement) }
        try bind(tokens.joined(separator: " AND "), to: statement, index: 1)
        var result = Set<String>()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try Task.checkCancellation()
            result.insert(try column(statement, index: 0))
            status = sqlite3_step(statement)
        }
        try checkManualIndexStatus(status, expected: SQLITE_DONE, database: database, path: path, operation: "search full text")
        return result
    }

    private func bind(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        let status = value.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        try checkManualIndexStatus(status, expected: SQLITE_OK, database: database, path: path, operation: "bind text parameter")
    }

    private func reset(_ statement: OpaquePointer) throws {
        try checkManualIndexStatus(sqlite3_reset(statement), expected: SQLITE_OK, database: database, path: path, operation: "reset prepared statement")
        try checkManualIndexStatus(sqlite3_clear_bindings(statement), expected: SQLITE_OK, database: database, path: path, operation: "clear prepared statement bindings")
    }

    private func column(_ statement: OpaquePointer, index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT, let text = sqlite3_column_text(statement, index) else {
            throw ManualIndexError(path: path, extendedCode: SQLITE_CORRUPT, operation: "read required text column \(index)", detail: "Persisted manual metadata is not text", rollbackDetail: nil)
        }
        return String(cString: text)
    }
}

private func initializeManualIndex(database: OpaquePointer, path: String) throws {
    try Task.checkCancellation()
    try executeManualIndexSQL(database: database, path: path, sql: "BEGIN IMMEDIATE")
    do {
        try executeManualIndexSQL(database: database, path: path, sql: "CREATE VIRTUAL TABLE IF NOT EXISTS manuals_v3 USING fts5(id UNINDEXED, fingerprint UNINDEXED, description, body, diagnostic UNINDEXED)")
        let exists = try prepareManualIndexSQL(database: database, path: path, sql: "SELECT 1 FROM sqlite_master WHERE type='table' AND name='manuals_rowids_v1'")
        defer { sqlite3_finalize(exists) }
        let status = sqlite3_step(exists)
        if status == SQLITE_DONE {
            try executeManualIndexSQL(database: database, path: path, sql: "CREATE TABLE manuals_rowids_v1(id TEXT PRIMARY KEY NOT NULL,manual_rowid INTEGER NOT NULL UNIQUE)")
            try executeManualIndexSQL(database: database, path: path, sql: "INSERT INTO manuals_rowids_v1(id,manual_rowid) SELECT id,rowid FROM manuals_v3")
        } else {
            try checkManualIndexStatus(status, expected: SQLITE_ROW, database: database, path: path, operation: "inspect keyed lookup schema")
            try checkManualIndexStatus(sqlite3_step(exists), expected: SQLITE_DONE, database: database, path: path, operation: "finish lookup schema inspection")
        }
        let validate = try prepareManualIndexSQL(database: database, path: path, sql: "SELECT 1 FROM manuals_rowids_v1 AS m LEFT JOIN manuals_v3 AS f ON f.rowid=m.manual_rowid WHERE typeof(m.id)!='text' OR m.id='' OR typeof(m.manual_rowid)!='integer' OR f.rowid IS NULL OR f.id!=m.id UNION ALL SELECT 1 FROM manuals_v3 AS f LEFT JOIN manuals_rowids_v1 AS m ON m.manual_rowid=f.rowid WHERE m.id IS NULL LIMIT 1")
        defer { sqlite3_finalize(validate) }
        let validation = sqlite3_step(validate)
        if validation == SQLITE_ROW {
            throw ManualIndexError(path: path, extendedCode: SQLITE_CORRUPT, operation: "validate keyed manual lookup", detail: "The ID-to-rowid table does not match retained full-text records; preserve this index and rebuild an app-owned copy", rollbackDetail: nil)
        }
        try checkManualIndexStatus(validation, expected: SQLITE_DONE, database: database, path: path, operation: "validate keyed manual lookup")
        try Task.checkCancellation()
        try executeManualIndexSQL(database: database, path: path, sql: "COMMIT")
    } catch {
        throw rollbackManualIndex(database: database, path: path, original: error)
    }
}

private func prepareManualIndexSQL(database: OpaquePointer, path: String, sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard status == SQLITE_OK, let statement else {
        if let statement { sqlite3_finalize(statement) }
        throw manualIndexError(database: database, path: path, operation: sql, status: status)
    }
    return statement
}

private func executeManualIndexSQL(database: OpaquePointer, path: String, sql: String) throws {
    let statement = try prepareManualIndexSQL(database: database, path: path, sql: sql)
    defer { sqlite3_finalize(statement) }
    try checkManualIndexStatus(sqlite3_step(statement), expected: SQLITE_DONE, database: database, path: path, operation: sql)
}

private func checkManualIndexStatus(_ status: Int32, expected: Int32, database: OpaquePointer, path: String, operation: String) throws {
    guard status == expected else { throw manualIndexError(database: database, path: path, operation: operation, status: status) }
}

private func manualIndexError(database: OpaquePointer?, path: String, operation: String, status: Int32) -> ManualIndexError {
    ManualIndexError(path: path, extendedCode: database.map(sqlite3_extended_errcode) ?? status, operation: operation,
                     detail: database.map { String(cString: sqlite3_errmsg($0)) } ?? "No database handle", rollbackDetail: nil)
}

private func rollbackManualIndex(database: OpaquePointer, path: String, original: Error) -> Error {
    do {
        try executeManualIndexSQL(database: database, path: path, sql: "ROLLBACK")
        return original
    } catch {
        if let failure = original as? ManualIndexError {
            return ManualIndexError(path: failure.path, extendedCode: failure.extendedCode, operation: failure.operation,
                                    detail: failure.detail, rollbackDetail: error.localizedDescription)
        }
        return ManualIndexError(path: path, extendedCode: SQLITE_ABORT, operation: "roll back interrupted indexing",
                                detail: original.localizedDescription, rollbackDetail: error.localizedDescription)
    }
}

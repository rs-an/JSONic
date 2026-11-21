import Foundation
import CryptoKit
import CSQLite

final class DB {
    var handle: OpaquePointer?
    private var cancellation: Cancellation?
    func interruptible(_ token: Cancellation) {
        cancellation = token
        sqlite3_progress_handler(handle, 1000, { pointer in
            guard let pointer else { return 0 }
            return Unmanaged<Cancellation>.fromOpaque(pointer).takeUnretainedValue().isCancelled ? 1 : 0
        }, Unmanaged.passUnretained(token).toOpaque())
    }
    init(_ url: URL) throws {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle); handle = nil
            throw ScopeError("Не удалось открыть индекс SQLite.")
        }
        sqlite3_busy_timeout(handle, 5000)
    }
    deinit { sqlite3_close(handle) }
    func exec(_ sql: String) throws {
        let code = sqlite3_exec(handle, sql, nil, nil, nil)
        if code == SQLITE_INTERRUPT { throw CancellationError() }
        guard code == SQLITE_OK else { throw error() }
    }
    func error() -> ScopeError { ScopeError("SQLite: " + String(cString: sqlite3_errmsg(handle))) }
    func statement(_ sql: String) throws -> Statement { try Statement(self, sql) }
}
final class Statement {
    let db: DB
    var handle: OpaquePointer?
    init(_ db: DB, _ sql: String) throws {
        self.db = db
        guard sqlite3_prepare_v2(db.handle, sql, -1, &handle, nil) == SQLITE_OK else { throw db.error() }
    }
    deinit { sqlite3_finalize(handle) }
    func text(_ index: Int32, _ value: String) { value.withCString { p in _ = sqlite3_bind_text(handle, index, p, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) } }
    func integer(_ index: Int32, _ value: Int64) { sqlite3_bind_int64(handle, index, value) }
    func step() throws -> Bool {
        let code = sqlite3_step(handle)
        if code == SQLITE_ROW { return true }
        if code == SQLITE_DONE { return false }
        if code == SQLITE_INTERRUPT { throw CancellationError() }
        throw db.error()
    }
    func reset() { sqlite3_reset(handle); sqlite3_clear_bindings(handle) }
    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }
    func string(_ column: Int32) -> String {
        guard let p = sqlite3_column_text(handle, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(handle, column))), as: UTF8.self)
    }
}
public struct SearchSpec: Equatable, Sendable {
    public var text: String
    public var columns: Set<Int>
    public var caseSensitive: Bool
    public init(text: String = "", columns: Set<Int> = [], caseSensitive: Bool = false) { self.text = text; self.columns = columns; self.caseSensitive = caseSensitive }
    public func matches(_ fields: [String]) -> Bool {
        if text.isEmpty { return true }
        let needle = caseSensitive ? text : text.lowercased()
        return fields.enumerated().contains { index, value in
            (columns.isEmpty || columns.contains(index)) && (caseSensitive ? value : value.lowercased()).contains(needle)
        }
    }
}
public struct RowPreview: Identifiable, Sendable {
    public let id: Int64
    public let values: [String]
}
public struct SearchPage: Sendable {
    public let rows: [RowPreview]
    public let cursor: Int64
    public let exhausted: Bool
}
public struct CellID: Hashable, Codable, Sendable {
    public let row: Int64
    public let column: Int
    public init(row: Int64, column: Int) { self.row = row; self.column = column }
}
struct Fingerprint: Codable, Equatable {
    let size: UInt64
    let modified: Double
    let fileID: UInt64
    static func read(_ url: URL) throws -> Fingerprint {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return Fingerprint(size: (a[.size] as? NSNumber)?.uint64Value ?? 0, modified: (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, fileID: (a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
}
public final class CSVStore: @unchecked Sendable {
    public let source: URL
    public let originalSource: URL?
    private let originalFingerprint: Fingerprint?
    private let retainedImport: AnyObject?
    public let format: CSVFormat
    public let headers: [String]
    public let cache: URL
    public let size: UInt64
    private let fingerprint: Fingerprint
    public static var cacheRoot: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("JSONic", isDirectory: true) }
    public init(source: URL, format: CSVFormat, cacheRoot: URL? = nil, originalSource: URL? = nil, retaining: AnyObject? = nil) throws {
        self.source = source; self.format = format
        self.originalSource = originalSource; self.retainedImport = retaining
        self.originalFingerprint = try originalSource.map { try Fingerprint.read($0) }
        fingerprint = try Fingerprint.read(source); size = fingerprint.size
        let reader = try CSVReader(url: source, format: format)
        guard let first = try reader.next() else { throw ScopeError("CSV пуст.") }
        headers = try parse(first.data, format: format)
        let root = cacheRoot ?? Self.cacheRoot
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = source.standardizedFileURL.path + "|" + String(format.delimiter) + "|" + format.encoding.rawValue
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        cache = root.appendingPathComponent(digest + ".sqlite")
        if !FileManager.default.fileExists(atPath: cache.path) {
            guard FileManager.default.createFile(atPath: cache.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ScopeError("Не удалось создать индекс SQLite.")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cache.path)
        let db = try DB(cache)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA cache_size=-8192; CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);")
        let q = try db.statement("SELECT value FROM meta WHERE key='identity'")
        let identity = String(data: try JSONEncoder().encode(fingerprint), encoding: .utf8)!
        // Canonical JSON order is not guaranteed; compare decoded identities instead.
        let reusable = try q.step() && (try? JSONDecoder().decode(Fingerprint.self, from: Data(q.string(0).utf8))) == fingerprint
        q.reset() // Release the metadata read cursor before rebuilding tables.
        if !reusable {
            try db.exec("DROP TABLE IF EXISTS records; DROP TABLE IF EXISTS search; DELETE FROM meta;")
            try db.exec("CREATE TABLE records (id INTEGER PRIMARY KEY, offset INTEGER, length INTEGER, preview TEXT); CREATE VIRTUAL TABLE search USING fts5(value, content='', tokenize='trigram');")
            let put = try db.statement("INSERT INTO meta VALUES ('identity', ?)"); put.text(1, identity); _ = try put.step()
        }
    }
    private let editLock = NSRecursiveLock()
    private let editsURL = FileManager.default.temporaryDirectory.appendingPathComponent("jsonic-edits-\(UUID().uuidString).sqlite")
    private var revision = 0
    public var editRevision: Int { editLock.lock(); defer { editLock.unlock() }; return revision }
    deinit { try? FileManager.default.removeItem(at: editsURL) }
    public func setCell(row: Int64, column: Int, value: String) throws {
        editLock.lock(); defer { editLock.unlock() }
        try validate()
        guard headers.indices.contains(column), try status().complete else { throw ScopeError("Дождитесь загрузки таблицы.") }
        _ = try readRow(row)
        if !FileManager.default.fileExists(atPath: editsURL.path) {
            guard FileManager.default.createFile(atPath: editsURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ScopeError("Не удалось сохранить правку.") }
        }
        let db = try DB(editsURL)
        try db.exec("CREATE TABLE IF NOT EXISTS edits(row INTEGER, col INTEGER, value TEXT, PRIMARY KEY(row,col))")
        let q = try db.statement("INSERT OR REPLACE INTO edits VALUES(?,?,?)")
        q.integer(1, row); q.integer(2, Int64(column)); q.text(3, value); _ = try q.step()
        revision += 1
    }
    private func edited(_ values: [String], row: Int64) throws -> [String] {
        editLock.lock(); defer { editLock.unlock() }
        guard revision > 0 else { return values }
        var result = values
        let db = try DB(editsURL), q = try db.statement("SELECT col,value FROM edits WHERE row=?")
        q.integer(1, row)
        while try q.step() { let col = Int(q.int(0)); if result.indices.contains(col) { result[col] = q.string(1) } }
        return result
    }
    public func validate() throws {
        if let originalSource, try Fingerprint.read(originalSource) != originalFingerprint { throw ScopeError("Книга Excel изменилась. Откройте её заново: индекс и выделение сброшены.") }
        if try Fingerprint.read(source) != fingerprint { throw ScopeError("Исходный файл изменился. Откройте его заново: индекс и выделение сброшены.") }
    }
    public func status() throws -> (count: Int64, complete: Bool) {
        let db = try DB(cache), q = try db.statement("SELECT count(*) FROM records")
        _ = try q.step()
        let done = try db.statement("SELECT value FROM meta WHERE key='complete'")
        return (q.int(0), try done.step())
    }
    public func build(_ token: Cancellation, progress: @escaping (Int64, Double) -> Void) throws {
        try validate()
        let db = try DB(cache)
        db.interruptible(token)
        let status = try status()
        if status.complete { progress(status.count, 1); return }
        // Partial indexes are restarted; only committed batches are visible to readers.
        try db.exec("BEGIN; DELETE FROM records; INSERT INTO search(search) VALUES('delete-all'); COMMIT;")
        let reader = try CSVReader(url: source, format: format)
        _ = try reader.next(token)
        let row = try db.statement("INSERT INTO records VALUES (?, ?, ?, ?)")
        let fts = try db.statement("INSERT INTO search(rowid,value) VALUES (?, ?)")
        var count: Int64 = 0, bytes: UInt64 = 0, last = Date()
        try db.exec("BEGIN")
        do {
            while let record = try reader.next(token) {
                try autoreleasepool {
                try token.check()
                let fields = try parse(record.data, format: format)
                if fields.count != headers.count { throw ScopeError("Строка \(count + 1): \(fields.count) колонок вместо \(headers.count). Проверьте разделитель.") }
                count += 1
                let preview = fields.map { String($0.prefix(180)).replacingOccurrences(of: "\n", with: " ↵ ") }
                let json = String(data: try JSONEncoder().encode(preview), encoding: .utf8)!
                row.integer(1, count); row.integer(2, Int64(record.offset)); row.integer(3, Int64(record.data.count)); row.text(4, json)
                _ = try row.step(); row.reset()
                fts.integer(1, count); fts.text(2, fields.joined(separator: "\n").lowercased()); _ = try fts.step(); fts.reset()
                bytes = record.offset + UInt64(record.data.count)
                if Date().timeIntervalSince(last) >= 0.35 {
                    try db.exec("COMMIT"); try validate(); progress(count, Double(bytes) / Double(max(size,1)))
                    try db.exec("BEGIN"); last = Date()
                }
                }
            }
            try token.check(); try validate()
            try db.exec("INSERT OR REPLACE INTO meta VALUES('complete','1'); COMMIT;")
            progress(count, 1)
        } catch { try? db.exec("ROLLBACK"); throw error }
    }
    private func candidateQuery(_ db: DB, spec: SearchSpec, after: Int64) throws -> Statement {
        let needle = spec.text.lowercased()
        let useIndex = needle.unicodeScalars.count >= 3 && !needle.contains("\0")
        if editRevision > 0 {
            let attach = try db.statement("ATTACH DATABASE ? AS draft")
            attach.text(1, editsURL.path); _ = try attach.step()
        }
        let editedCandidates = editRevision > 0 ? " UNION SELECT row FROM draft.edits" : ""
        let sql = useIndex ? "SELECT r.id,r.offset,r.length,r.preview FROM records r WHERE r.id IN (SELECT rowid FROM search WHERE search MATCH ?\(editedCandidates)) AND r.id>? ORDER BY r.id" : "SELECT id,offset,length,preview FROM records WHERE id>? ORDER BY id"
        let q = try db.statement(sql)
        if useIndex { q.text(1, "\"" + needle.replacingOccurrences(of: "\"", with: "\"\"") + "\""); q.integer(2, after) }
        else { q.integer(1, after) }
        return q
    }
    private func fields(_ q: Statement, handle: FileHandle) throws -> [String] {
        try handle.seek(toOffset: UInt64(q.int(1)))
        let count = Int(q.int(2))
        let data = try handle.read(upToCount: count) ?? Data()
        if data.count != count { throw ScopeError("Исходный файл изменился или не прочитан полностью.") }
        return try edited(parse(data, format: format), row: q.int(0))
    }
    public func readRow(_ id: Int64) throws -> [String] {
        try validate()
        let db = try DB(cache), q = try db.statement("SELECT id,offset,length FROM records WHERE id=?")
        q.integer(1,id)
        guard try q.step() else { throw ScopeError("Запись недоступна в индексе.") }
        let h = try FileHandle(forReadingFrom: source); defer { try? h.close() }
        return try fields(q, handle: h)
    }
    public func page(spec: SearchSpec, after: Int64 = 0, limit: Int = 100, wrappedPreview: Bool = false, token: Cancellation) throws -> SearchPage {
        try validate()
        let db = try DB(cache)
        db.interruptible(token)
        let q = try candidateQuery(db, spec: spec, after: after)
        let h = try FileHandle(forReadingFrom: source); defer { try? h.close() }
        var rows = [RowPreview](), cursor = after
        while try q.step() {
            try token.check(); cursor = q.int(0)
            let matched: RowPreview? = try autoreleasepool {
                if try spec.text.isEmpty || spec.matches(fields(q, handle: h)) {
                    let preview: [String]
                    if wrappedPreview || editRevision > 0 {
                        preview = try fields(q, handle: h).map {
                            let cap = wrappedPreview ? 4000 : 180
                            let prefix = String($0.prefix(cap + 1))
                            let truncated = prefix.count > cap
                            let bounded = String(prefix.prefix(cap))
                            let value = wrappedPreview ? bounded : bounded.replacingOccurrences(of: "\n", with: " ↵ ")
                            return value + (truncated ? "…" : "")
                        }
                    } else { preview = try JSONDecoder().decode([String].self, from: Data(q.string(3).utf8)) }
                    return RowPreview(id: cursor, values: preview)
                }
                return nil
            }
            if let matched {
                rows.append(matched)
                if rows.count == limit { return SearchPage(rows: rows, cursor: cursor, exhausted: false) }
            }
        }
        try validate()
        return SearchPage(rows: rows, cursor: cursor, exhausted: true)
    }
    public func visit(spec: SearchSpec = SearchSpec(), token: Cancellation, body: (Int64, [String]) throws -> Void) throws {
        try validate()
        let db = try DB(cache)
        db.interruptible(token)
        let q = try candidateQuery(db, spec: spec, after: 0)
        let h = try FileHandle(forReadingFrom: source); defer { try? h.close() }
        while try q.step() {
            try token.check()
            try autoreleasepool {
                let values = try fields(q, handle: h)
                if spec.matches(values) { try body(q.int(0), values) }
            }
        }
        try validate()
    }
    public func deleteCache() throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = cache.path + suffix
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        }
    }
}

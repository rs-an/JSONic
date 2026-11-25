import Foundation
import CryptoKit

// Nodes contain locations and replacement identifiers, never a prepared output cell.
private struct TextHit: Codable {
    let location: Int
    let length: Int
    let identity: String
    let replacement: String
}
private indirect enum MaskNode: Codable {
    case whole(String, String)
    case text([TextHit])
    case object([String: MaskNode])
    case array([Int: MaskNode])
    case envelope(prefix: MaskNode?, value: MaskNode?, suffix: MaskNode?)
}
public struct JSONIssue: Sendable {
    public let row: Int64
    public let column: String
    public let reason: String
}

/// A session is confined to one worker at a time; the UI only retains its reference.
public final class MaskAnalysis: @unchecked Sendable {
    private let db: DB
    private let temporary: URL
    private let request: ExportRequest
    private let source: URL
    private let editRevision: Int
    private let fingerprint: Fingerprint
    private let format: CSVFormat
    private var base = ExportReport()
    private var counters: [MaskKind: Int] = [:]
    private let getMapping: Statement
    private let putMapping: Statement
    private let countMapping: Statement
    private let putCell: Statement
    private let getCell: Statement
    private var cache: [String: (String, String)] = [:]
    private var textCache: [String: [TextHit]] = [:]
    private let detector = PersonalDataDetector()
    private var names: [(NSRegularExpression, String)] = []
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var row: Int64 = 0
    private var column = ""
    private var warned = false
    private var finalized = false
    private var singleScalarNode: MaskNode?
    private var singleWholeIdentity: String?
    private var token = Cancellation()

    init(store: CSVStore, request: ExportRequest) throws {
        editRevision = store.editRevision
        self.request = request; source = store.source; format = store.format
        fingerprint = try Fingerprint.read(source)
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("jsonic-analysis-\(UUID().uuidString).sqlite")
        // Create with restrictive permissions before SQLite opens it.
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ScopeError("Не удалось создать индекс анализа. Проверьте свободное место.") }
        do {
            db = try DB(temporary)
            try db.exec("PRAGMA journal_mode=OFF; PRAGMA cache_size=-2048; CREATE TABLE mapping (id INTEGER PRIMARY KEY, identity TEXT UNIQUE, original TEXT, replacement TEXT, rule TEXT, occurrences INTEGER DEFAULT 0); CREATE TABLE cells (row INTEGER, col INTEGER, plan TEXT, PRIMARY KEY(row,col)); CREATE TEMP TABLE excluded (identity TEXT PRIMARY KEY); BEGIN;")
            getMapping = try db.statement("SELECT identity,replacement FROM mapping WHERE identity=?")
            putMapping = try db.statement("INSERT INTO mapping(identity,original,replacement,rule) VALUES (?,?,?,?)")
            countMapping = try db.statement("UPDATE mapping SET occurrences=occurrences+1 WHERE identity=?")
            putCell = try db.statement("INSERT INTO cells VALUES (?,?,?)")
            getCell = try db.statement("SELECT plan FROM cells WHERE row=? AND col=?")
            for group in request.rules.names {
                guard let canonical = group.first, !canonical.isEmpty else { continue }
                let alternatives = group.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
                names.append((try NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])(?:"# + alternatives + #")(?![\p{L}\p{N}_])"#, options: [.caseInsensitive]), canonical.lowercased()))
            }
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
    deinit { try? FileManager.default.removeItem(at: temporary) }

    public func validate(store: CSVStore, request other: ExportRequest) throws {
        try store.validate()
        var a = request.rules, b = other.rules
        a.excluded = []; b.excluded = []
        guard finalized, editRevision == store.editRevision, source.standardizedFileURL == store.source.standardizedFileURL,
              fingerprint == (try Fingerprint.read(source)), format.delimiter == store.format.delimiter,
              format.encoding == store.format.encoding, request.scope == other.scope,
              request.rows == other.rows, request.cells == other.cells, request.search == other.search,
              a == b else { throw ScopeError("Исходник или правила изменены — обновите анализ перед сохранением.") }
    }
    private func mapping(_ value: String, kind: MaskKind, rule: String, canonical: String? = nil) throws -> (String, String) {
        try token.check()
        var key = canonical ?? value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if kind == .phone {
            key = value.filter { $0.isNumber }
            if key.count == 11 && (key.first == "8" || key.first == "7") { key = "7" + key.dropFirst() }
            if key.count == 10 { key = "7" + key }
            if key.isEmpty { key = value }
        } else if kind == .person && canonical == nil {
            for group in request.rules.names where group.contains(where: { $0.lowercased() == key }) { key = group[0].lowercased(); break }
        }
        if MaskKind.additional.contains(kind) { key = StructuredDataDetector.canonical(value, kind: kind) }
        let cacheKey = kind.rawValue + ":" + key
        if let result = cache[cacheKey] { return result }
        let identity = SHA256.hash(data: Data(cacheKey.utf8)).map { String(format: "%02x", $0) }.joined()
        getMapping.reset(); getMapping.text(1, identity)
        let result: (String, String)
        if try getMapping.step() { result = (identity, getMapping.string(1)) }
        else {
            counters[kind, default: 0] += 1
            let replacement = String(format: "%@_%03d", kind.rawValue, counters[kind]!)
            putMapping.reset(); putMapping.text(1, identity); putMapping.text(2, String(value.prefix(160))); putMapping.text(3, replacement); putMapping.text(4, rule); _ = try putMapping.step()
            result = (identity, replacement)
        }
        if cache.count >= 2048 { cache.removeAll(keepingCapacity: true) }
        if cacheKey.utf8.count < 4096 { cache[cacheKey] = result }
        return result
    }
    private func count(_ identity: String) throws {
        countMapping.reset(); countMapping.text(1, identity); _ = try countMapping.step()
    }
    private func whole(_ value: String, kind: MaskKind, rule: String) throws -> MaskNode? {
        guard !value.isEmpty else { return nil }
        let (id, replacement) = try mapping(value, kind: kind, rule: rule)
        try count(id)
        return .whole(id, replacement)
    }
    private func text(_ input: String) throws -> MaskNode? {
        try token.check()
        guard !input.isEmpty else { return nil }
        if let hits = textCache[input] {
            for hit in hits { try token.check(); try count(hit.identity) }
            return hits.isEmpty ? nil : .text(hits)
        }
        let ns = input as NSString
        var candidates: [(NSRange, MaskKind, String, String?, Bool)] = []
        // Explicit names precede automatic rules; reject overlapping lower-priority matches.
        for (regex, canonical) in names {
            try token.check()
            for match in try cancellableMatches(regex, in: input, range: NSRange(location: 0, length: ns.length), token: token) {
                candidates.append((match.range, .person, "Список имён", canonical, true))
            }
        }
        // Reserve explicit/structured values even for disabled types: a password or
        // email must not accidentally become a PHONE/PERSON through a substring match.
        for hit in try StructuredDataDetector.matches(input, enabled: Set(MaskKind.additional), token: token) {
            candidates.append((hit.range, hit.kind, hit.reason, nil, request.rules.additionalTypes.contains(hit.kind)))
        }
        if request.rules.phonesInText {
            try token.check()
            for match in try cancellableMatches(PersonalDataDetector.phone, in: input, range: NSRange(location: 0, length: ns.length), token: token) {
                candidates.append((match.range, .phone, "Телефон в тексте", nil, true))
            }
        }
        if request.rules.automaticNames {
            try token.check()
            for match in try detector.people(input, token: token) { candidates.append((match.range, .person, match.reason, match.canonical, true)) }
        }
        var occupied = IndexSet(), hits: [TextHit] = []
        for (range, kind, rule, canonical, enabled) in candidates {
            try token.check()
            let indexes = range.location..<NSMaxRange(range)
            guard !occupied.intersects(integersIn: indexes) else { continue }
            occupied.insert(integersIn: indexes)
            guard enabled else { continue }
            let (id, replacement) = try mapping(ns.substring(with: range), kind: kind, rule: rule, canonical: canonical)
            hits.append(TextHit(location: range.location, length: range.length, identity: id, replacement: replacement))
            try count(id)
        }
        hits.sort { $0.location > $1.location }
        if textCache.count >= 1024 { textCache.removeAll(keepingCapacity: true) }
        if ns.length <= 2048 && hits.count <= 32 { textCache[input] = hits }
        return hits.isEmpty ? nil : .text(hits)
    }
    private func automaticKind(_ field: String) -> MaskKind? {
        let key = PersonalDataDetector.key(field)
        if request.rules.phonesInText && PersonalDataDetector.phoneKeys.contains(key) { return .phone }
        if request.rules.automaticNames && PersonalDataDetector.personKeys.contains(key) { return .person }
        return StructuredDataDetector.fieldKind(field)
    }
    private func scalar(_ value: Any) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
    private func walk(_ object: Any, depth: Int, inherited: MaskKind? = nil) throws -> MaskNode? {
        try token.check()
        guard depth <= 128 else { throw ScopeError("Слишком глубокий JSON: анализ остановлен.") }
        if let dict = object as? [String: Any] {
            var result: [String: MaskNode] = [:]
            for key in dict.keys.sorted() {
                let value = dict[key]!
                if let explicit = request.rules.keys[key.lowercased()], !(value is NSNull) {
                    let string = try scalar(value) ?? String(decoding: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
                    result[key] = try whole(string, kind: explicit, rule: "JSON: " + key)
                } else if let kind = automaticKind(key) ?? inherited {
                    result[key] = try contextual(value, kind: kind, rule: "JSON: " + key, depth: depth + 1)
                } else { result[key] = try walk(value, depth: depth + 1) }
            }
            return result.isEmpty ? nil : .object(result)
        }
        if let array = object as? [Any] {
            var result: [Int: MaskNode] = [:]
            for (i, value) in array.enumerated() { result[i] = try walk(value, depth: depth + 1, inherited: inherited) }
            return result.isEmpty ? nil : .array(result)
        }
        if let inherited, let string = scalar(object) { return try whole(string, kind: inherited, rule: "Контекст поля: " + inherited.title) }
        if let string = object as? String { return try transform(string, depth: depth + 1) }
        if request.rules.phonesInText, let n = object as? NSNumber, PersonalDataDetector.isPhone(n.stringValue) {
            return try whole(n.stringValue, kind: .phone, rule: "Числовое значение похоже на телефон")
        }
        return nil
    }
    private func contextual(_ value: Any, kind: MaskKind, rule: String, depth: Int) throws -> MaskNode? {
        if kind == .address, let string = scalar(value), StructuredDataDetector.canonicalIP(string) != nil {
            return try contextual(value, kind: .ip, rule: rule + " (IP)", depth: depth)
        }
        if MaskKind.additional.contains(kind) && !request.rules.additionalTypes.contains(kind) { return nil }
        if let string = scalar(value) {
            if kind == .login && StructuredDataDetector.isAbsentLogin(string) { return nil }
            // The outer CSV/JSON field supplies context even when its value is nested JSON text.
            if kind != .secret, let text = value as? String, let envelope = try extractJSON(text, token: token) {
                let context = MaskKind.additional.contains(kind) ? kind : nil
                let body = try walk(envelope.value, depth: depth + 1, inherited: context)
                let prefix = try self.text(envelope.prefix), suffix = try transform(envelope.suffix, depth: depth + 1)
                if body == nil && prefix == nil && suffix == nil { return nil }
                return .envelope(prefix: prefix, value: body, suffix: suffix)
            }
            // A complete, unambiguous token can refine a field hint. Never partially
            // mask a contextual value (especially a credential or a full address).
            if kind != .secret, let hit = try StructuredDataDetector.matches(string, enabled: request.rules.additionalTypes.intersection([.email]), token: token).first(where: { $0.range == NSRange(string.startIndex..., in: string) && $0.kind != kind }) {
                return try whole(string, kind: hit.kind, rule: hit.reason)
            }
            var description = rule
            if kind == .inn { description += StructuredDataDetector.validINN(string) ? " · контрольное число верно" : " · проверить ИНН" }
            if kind == .snils { description += StructuredDataDetector.validSNILS(string) ? " · контрольное число верно" : " · проверить СНИЛС" }
            return try whole(string, kind: kind, rule: description)
        }
        return try walk(value, depth: depth + 1, inherited: MaskKind.additional.contains(kind) ? kind : nil)
    }
    private func transform(_ input: String, depth: Int = 0) throws -> MaskNode? {
        try token.check()
        guard depth <= 128 else { throw ScopeError("Слишком глубокий JSON: анализ остановлен.") }
        switch try inspectJSON(input, token: token) {
        case .json(let envelope):
            let prefix = try text(envelope.prefix)
            let value = try walk(envelope.value, depth: depth + 1)
            let suffix = try transform(envelope.suffix, depth: depth + 1)
            if prefix == nil && value == nil && suffix == nil { return nil }
            return .envelope(prefix: prefix, value: value, suffix: suffix)
        case .invalid(let reason):
            if !warned {
                warned = true; base.malformedJSON += 1
                if base.issues.count < 80 { base.issues.append(JSONIssue(row: row, column: column, reason: reason)) }
            }
            return try text(input)
        case .text: return try text(input)
        }
    }
    func analyze(_ input: String, row: Int64, col: Int, column: String, token: Cancellation) throws {
        self.token = token; self.row = row; self.column = column; warned = false
        if request.scope == .cells && request.cells.count == 1 {
            base.singleValueIsJSON = (try? JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed])) != nil
        }
        guard request.rules.enabled else { return }
        let node: MaskNode?
        if let kind = request.rules.columns[column.lowercased()] { node = try whole(input, kind: kind, rule: "Колонка: " + column) }
        else if let kind = automaticKind(column) { node = try contextual(input, kind: kind, rule: "Колонка: " + column, depth: 0) }
        else { node = try transform(input) }
        if let node {
            if request.scope == .cells && request.cells.count == 1 {
                if case .whole(let id, _) = node { singleWholeIdentity = id }
                if base.singleValueIsJSON == true, input.trimmingCharacters(in: .whitespacesAndNewlines).first != "\"", case .text = node { singleScalarNode = node }
            }
            try token.check()
            let data = try encoder.encode(node)
            putCell.reset(); putCell.integer(1, row); putCell.integer(2, Int64(col)); putCell.text(3, String(decoding: data, as: UTF8.self)); _ = try putCell.step()
        }
    }
    func finish(_ report: ExportReport) throws {
        base.records = report.records
        try db.exec("COMMIT"); finalized = true
        cache.removeAll(); textCache.removeAll()
    }
    public func report(excluded: Set<String> = [], offset: Int = 0, limit: Int = 80) throws -> ExportReport {
        guard finalized else { throw ScopeError("Анализ не завершён.") }
        try db.exec("DELETE FROM excluded; BEGIN")
        do {
            let insert = try db.statement("INSERT INTO excluded VALUES (?)")
            for id in excluded { insert.reset(); insert.text(1, id); _ = try insert.step() }
            try db.exec("COMMIT")
        } catch { try? db.exec("ROLLBACK"); throw error }
        var report = base
        if let id = singleWholeIdentity, !excluded.contains(id) { report.singleValueIsJSON = false }
        if let node = singleScalarNode, try active(node, excluded: excluded, token: Cancellation()) { report.singleValueIsJSON = false }
        let counts = try db.statement("SELECT COUNT(*),COALESCE(SUM(occurrences),0),COALESCE(SUM(CASE WHEN identity IN (SELECT identity FROM excluded) THEN occurrences ELSE 0 END),0) FROM mapping")
        _ = try counts.step(); report.exampleCount = Int(counts.int(0)); report.skipped = counts.int(2); report.replacements = counts.int(1) - report.skipped
        let page = try db.statement("SELECT id,identity,original,replacement,rule FROM mapping ORDER BY id LIMIT ? OFFSET ?")
        page.integer(1, Int64(max(1, min(limit, 80)))); page.integer(2, Int64(max(0, offset)))
        while try page.step() { report.examples.append(MaskExample(id: Int(page.int(0)), identity: page.string(1), original: page.string(2), replacement: page.string(3), rule: page.string(4))) }
        return report
    }
    func apply(_ input: String, row: Int64, col: Int, excluded: Set<String>, token: Cancellation) throws -> String {
        try token.check()
        getCell.reset(); getCell.integer(1, row); getCell.integer(2, Int64(col))
        guard try getCell.step() else { return input }
        let node = try decoder.decode(MaskNode.self, from: Data(getCell.string(0).utf8))
        return try applying(node, to: input, excluded: excluded, token: token) as? String ?? input
    }
    private func active(_ node: MaskNode, excluded: Set<String>, token: Cancellation) throws -> Bool {
        try token.check()
        switch node {
        case .whole(let id, _): return !excluded.contains(id)
        case .text(let hits): return hits.contains { !excluded.contains($0.identity) }
        case .object(let nodes): for node in nodes.values { if try active(node, excluded: excluded, token: token) { return true } }; return false
        case .array(let nodes): for node in nodes.values { if try active(node, excluded: excluded, token: token) { return true } }; return false
        case .envelope(let p, let v, let s): for node in [p,v,s].compactMap({ $0 }) { if try active(node, excluded: excluded, token: token) { return true } }; return false
        }
    }
    private func applying(_ node: MaskNode, to value: Any, excluded: Set<String>, token: Cancellation) throws -> Any {
        try token.check()
        switch node {
        case .whole(let id, let replacement): return excluded.contains(id) ? value : replacement
        case .text(let hits):
            guard let string = value as? String else { throw ScopeError("Структура данных изменилась: повторите анализ.") }
            let result = NSMutableString(string: string)
            for hit in hits where !excluded.contains(hit.identity) {
                try token.check()
                guard hit.location + hit.length <= result.length else { throw ScopeError("Диапазон замены изменился: повторите анализ.") }
                result.replaceCharacters(in: NSRange(location: hit.location, length: hit.length), with: hit.replacement)
            }
            return result as String
        case .object(let nodes):
            guard var object = value as? [String: Any] else { throw ScopeError("Структура JSON изменилась.") }
            for (key, node) in nodes { guard let v = object[key] else { throw ScopeError("Структура JSON изменилась.") }; object[key] = try applying(node, to: v, excluded: excluded, token: token) }
            return object
        case .array(let nodes):
            guard var array = value as? [Any] else { throw ScopeError("Структура JSON изменилась.") }
            for (i, node) in nodes { guard array.indices.contains(i) else { throw ScopeError("Структура JSON изменилась.") }; array[i] = try applying(node, to: array[i], excluded: excluded, token: token) }
            return array
        case .envelope(let prefix, let body, let suffix):
            guard try active(node, excluded: excluded, token: token) else { return value }
            guard let string = value as? String, let envelope = try extractJSON(string, token: token) else { throw ScopeError("JSON изменился: повторите анализ.") }
            let p = try prefix.map { try applying($0, to: envelope.prefix, excluded: excluded, token: token) as! String } ?? envelope.prefix
            let s = try suffix.map { try applying($0, to: envelope.suffix, excluded: excluded, token: token) as! String } ?? envelope.suffix
            // Preserve the JSON bytes when only the surrounding text changed.
            let originalBody = String(string.dropFirst(envelope.prefix.count).dropLast(envelope.suffix.count))
            var json = originalBody
            if let body, try active(body, excluded: excluded, token: token) {
                let masked = try applying(body, to: envelope.value, excluded: excluded, token: token)
                try token.check()
                json = String(decoding: try JSONSerialization.data(withJSONObject: masked, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
            }
            return p + json + s
        }
    }
}

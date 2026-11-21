import Foundation
import Darwin

public enum MaskKind: String, CaseIterable, Sendable {
    case phone = "PHONE", person = "PERSON", email = "EMAIL", telegram = "TELEGRAM"
    case login = "LOGIN", inn = "INN", snils = "SNILS", passport = "PASSPORT"
    case address = "ADDRESS", ip = "IP", secret = "SECRET"
    public static let additional: [MaskKind] = [.email, .telegram, .login, .inn, .snils, .passport, .address, .ip, .secret]
    public static let defaultAdditional = Set(additional.filter { $0 != .ip })
    public var title: String {
        switch self {
        case .phone: return "Телефоны"
        case .person: return "Имена и ФИО"
        case .email: return "Email"
        case .telegram: return "Telegram"
        case .login: return "Логины"
        case .inn: return "ИНН"
        case .snils: return "СНИЛС"
        case .passport: return "Паспорта РФ"
        case .address: return "Адреса"
        case .ip: return "IP-адреса"
        case .secret: return "Пароли и токены"
        }
    }
}
public struct MaskRules: Sendable, Equatable {
    public var enabled = true
    public var phonesInText = true
    public var automaticNames = true
    public var additionalTypes: Set<MaskKind> = MaskKind.defaultAdditional
    public var excluded: Set<String> = []
    public var columns: [String: MaskKind] = [:]
    public var keys: [String: MaskKind] = [:]
    public var names: [[String]] = []
    public init() {}
}
public struct MaskExample: Identifiable, Sendable {
    public let id: Int
    public let identity: String
    public let original: String
    public let replacement: String
    public let rule: String
}
public struct ExportReport: Sendable {
    public var singleValueIsJSON: Bool? = nil
    public var records: Int64 = 0
    public var replacements: Int64 = 0
    public var skipped: Int64 = 0
    public var malformedJSON: Int64 = 0
    public var issues: [JSONIssue] = []
    public var exampleCount = 0
    public var examples: [MaskExample] = []
}
public enum ExportScope: String, CaseIterable, Sendable {
    case all = "Весь файл", results = "Результаты поиска", rows = "Выбранные строки", cells = "Выбранные ячейки"
}
public struct ExportRequest: Sendable {
    public var scope: ExportScope = .all
    public var search = SearchSpec()
    public var rows: Set<Int64> = []
    public var cells: Set<CellID> = []
    public var rules = MaskRules()
    public var singleValue = false
    public var protectSpreadsheetFormulas = true
    public init() {}
}
private func runExport(_ store: CSVStore, request: ExportRequest, destination: URL?, analysis: MaskAnalysis?, analyzing: Bool, token: Cancellation, progress: @escaping (Int64) -> Void = { _ in }) throws -> ExportReport {
    try store.validate()
    guard try store.status().complete else { throw ScopeError("Дождитесь завершения индексирования перед экспортом.") }
    if request.scope == .rows && request.rows.isEmpty { throw ScopeError("Не выбраны строки.") }
    if request.scope == .cells && request.cells.isEmpty { throw ScopeError("Не выбраны ячейки.") }
    if request.singleValue && (request.scope != .cells || request.cells.count != 1) { throw ScopeError("Выберите одну ячейку.") }
    if let destination {
        for protectedSource in [store.source, store.originalSource].compactMap({ $0 }) {
        if destination.resolvingSymlinksInPath().standardizedFileURL == protectedSource.resolvingSymlinksInPath().standardizedFileURL { throw ScopeError("Нельзя перезаписать исходный файл.") }
        if let a = try? FileManager.default.attributesOfItem(atPath: destination.path), let b = try? FileManager.default.attributesOfItem(atPath: protectedSource.path), (a[.systemFileNumber] as? NSNumber) == (b[.systemFileNumber] as? NSNumber), (a[.systemNumber] as? NSNumber) == (b[.systemNumber] as? NSNumber) { throw ScopeError("Нельзя перезаписать исходный файл.") }
        }
    }
    var report = ExportReport()
    func cellValue(_ value: String, row: Int64, col: Int) throws -> String {
        try token.check()
        if analyzing {
            try analysis?.analyze(value, row: row, col: col, column: store.headers[col], token: token)
            return value
        }
        return try analysis?.apply(value, row: row, col: col, excluded: request.rules.excluded, token: token) ?? value
    }
    func outputLine(_ values: [String]) -> Data {
        let safe = request.protectSpreadsheetFormulas ? values.map(spreadsheetSafeValue) : values
        return csvLine(safe, delimiter: store.format.delimiter)
    }
    let temporary = destination?.deletingLastPathComponent().appendingPathComponent(".jsonic-\(UUID().uuidString).tmp")
    var output: FileHandle?
    if let temporary {
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ScopeError("Не удалось создать файл экспорта. Проверьте свободное место и доступ.") }
        output = try FileHandle(forWritingTo: temporary)
    }
    defer { try? output?.close(); if let temporary { try? FileManager.default.removeItem(at: temporary) } }
    if !request.singleValue { try output?.write(contentsOf: outputLine(request.scope == .cells ? ["row_number", "column_name", "value"] : store.headers)) }
    let grouped = Dictionary(grouping: request.cells, by: \.row)
    var last = Date()
    func consume(_ id: Int64, _ values: [String]) throws {
        try token.check()
        if request.scope == .cells {
            for cell in (grouped[id] ?? []).sorted(by: { $0.column < $1.column }) {
                guard values.indices.contains(cell.column) else { throw ScopeError("Некорректная выбранная колонка.") }
                let value = try cellValue(values[cell.column], row: id, col: cell.column)
                if request.singleValue {
                    let data: Data
                    if let object = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]) {
                        report.singleValueIsJSON = true
                        data = analyzing ? Data() : try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
                    } else { report.singleValueIsJSON = false; data = Data(value.utf8) }
                    try output?.write(contentsOf: data)
                } else { try output?.write(contentsOf: outputLine([String(id), store.headers[cell.column], value])) }
                report.records += 1
            }
        } else {
            var masked = [String]()
            for (i, value) in values.enumerated() { masked.append(try cellValue(value, row: id, col: i)) }
            try output?.write(contentsOf: outputLine(masked))
            report.records += 1
        }
        if Date().timeIntervalSince(last) > 0.25 { progress(report.records); last = Date() }
    }
    if request.scope == .rows || request.scope == .cells {
        let ids = request.scope == .rows ? request.rows : Set(grouped.keys)
        for id in ids.sorted() { try token.check(); try autoreleasepool { try consume(id, store.readRow(id)) } }
    } else { try store.visit(spec: request.scope == .results ? request.search : SearchSpec(), token: token, body: consume) }
    try token.check(); try store.validate()
    try output?.synchronize(); try output?.close(); output = nil
    if let destination, let temporary {
        if rename(temporary.path, destination.path) != 0 { throw ScopeError("Не удалось сохранить экспорт: " + String(cString: strerror(errno))) }
    }
    progress(report.records)
    return report
}


public func analyzeExport(_ store: CSVStore, request: ExportRequest, token: Cancellation, progress: @escaping (Int64) -> Void = { _ in }) throws -> MaskAnalysis {
    let analysis = try MaskAnalysis(store: store, request: request)
    let report = try runExport(store, request: request, destination: nil, analysis: analysis, analyzing: true, token: token, progress: progress)
    try analysis.finish(report)
    return analysis
}

public func export(_ store: CSVStore, request: ExportRequest, destination: URL?, token: Cancellation, analysis prepared: MaskAnalysis? = nil, progress: @escaping (Int64) -> Void = { _ in }) throws -> ExportReport {
    let analysis: MaskAnalysis?
    if request.rules.enabled {
        if let prepared { try prepared.validate(store: store, request: request); analysis = prepared }
        else { analysis = try analyzeExport(store, request: request, token: token, progress: progress) }
    } else { analysis = nil }
    if destination == nil, let analysis { return try analysis.report(excluded: request.rules.excluded) }
    // Materialize the report before publishing a file, so a reporting error cannot look like a failed save.
    var report = try analysis?.report(excluded: request.rules.excluded) ?? ExportReport()
    let saved = try runExport(store, request: request, destination: destination, analysis: analysis, analyzing: false, token: token, progress: progress)
    report.records = saved.records; report.singleValueIsJSON = saved.singleValueIsJSON
    return report
}

// CSV quoting alone does not prevent spreadsheet applications from treating text as a formula.
private func spreadsheetSafeValue(_ value: String) -> String {
    let trimmed = value.drop(while: { $0.isWhitespace || $0.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) } })
    guard let first = trimmed.first else { return value }
    if "=+-@".contains(first) || value.first == "\t" || value.first == "\r" || value.first == "\n" {
        return "'" + value
    }
    return value
}

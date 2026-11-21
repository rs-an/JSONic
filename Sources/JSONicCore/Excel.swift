import Foundation
import ZIPFoundation
import CLibXLS

public struct ExcelSheet: Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let hidden: Bool
    let path: String
}
public struct ExcelWorkbook: Sendable {
    public let source: URL
    public let sheets: [ExcelSheet]
    let fingerprint: Fingerprint
    let date1904: Bool
    public static func supports(_ url: URL) -> Bool { ["xls", "xlsx"].contains(url.pathExtension.lowercased()) }
    public func validate() throws {
        guard try Fingerprint.read(source) == fingerprint else { throw ScopeError("Книга Excel изменилась — откройте её заново.") }
    }
    public static func open(_ source: URL, token: Cancellation) throws -> ExcelWorkbook {
        try token.check()
        let fingerprint = try Fingerprint.read(source)
        let sheets: [ExcelSheet], date1904: Bool
        if source.pathExtension.lowercased() == "xls" {
            let book = try openXLS(source); defer { xls_close_WB(book) }
            sheets = (0..<Int(book.pointee.sheets.count)).compactMap { i in
                let sheet = book.pointee.sheets.sheet[i]
                guard sheet.type == 0 else { return nil }
                return ExcelSheet(id: i, name: sheet.name.map { String(cString: $0) } ?? "Лист \(i + 1)", hidden: sheet.visibility != 0, path: "")
            }
            date1904 = book.pointee.is1904 != 0
        } else {
            let scratch = try ExcelImportResult()
            let zip = try ExcelZip(source, scratch: scratch.folder, token: token)
            // Resolve OOXML relationships rather than assuming worksheet file names.
            var workbookPath: String?
            try parseXML(zip.extract("_rels/.rels", limit: 16 << 20), token: token, start: { name, a in
                if name == "Relationship", a["Type"]?.hasSuffix("/officeDocument") == true, a["TargetMode"] != "External", let target = a["Target"] {
                    workbookPath = try resolvePart(target, relativeTo: "")
                }
            })
            guard let path = workbookPath else { throw ScopeError("В XLSX не найдена книга Excel.") }
            let rels = try zip.relationships(for: path)
            var result: [ExcelSheet] = [], mode = false
            try parseXML(zip.extract(path, limit: 16 << 20), token: token, start: { name, a in
                if name == "workbookPr" { mode = a["date1904"] == "1" || a["date1904"] == "true" }
                if name == "sheet", let id = a["r:id"] ?? a["id"], let relation = rels[id], relation.type.hasSuffix("/worksheet") {
                    result.append(ExcelSheet(id: result.count, name: a["name"] ?? "Лист \(result.count + 1)", hidden: a["state"] == "hidden" || a["state"] == "veryHidden", path: relation.path))
                }
            })
            sheets = result; date1904 = mode
        }
        try token.check()
        guard !sheets.isEmpty else { throw ScopeError("В книге нет листов с ячейками.") }
        let info = ExcelWorkbook(source: source, sheets: sheets, fingerprint: fingerprint, date1904: date1904)
        try info.validate(); return info
    }
    public func importSheet(_ sheetID: Int, token: Cancellation, progress: @escaping (String, Double) -> Void = { _, _ in }) throws -> ExcelImportResult {
        try validate(); try token.check()
        guard let sheet = sheets.first(where: { $0.id == sheetID }) else { throw ScopeError("Лист Excel не найден.") }
        let result = try ExcelImportResult(); result.sourceFingerprint = fingerprint
        let spool = try ExcelSpool(folder: result.folder, token: token)
        if source.pathExtension.lowercased() == "xls" {
            progress("Чтение XLS…", 0)
            let book = try Self.openXLS(source); defer { xls_close_WB(book) }
            guard let page = xls_getWorkSheet(book, Int32(sheet.id)) else { throw ScopeError("Не удалось открыть лист XLS.") }
            defer { xls_close_WS(page) }
            let error = xls_parseWorkSheet(page)
            try token.check()
            guard error == LIBXLS_OK else { throw ScopeError("Ошибка XLS: " + String(cString: xls_getError(error))) }
            var custom: [Int: String] = [:]
            for i in 0..<Int(book.pointee.formats.count) {
                let f = book.pointee.formats.format[i]
                if let value = f.value { custom[Int(f.index)] = String(cString: value) }
            }
            let rowCount = Int(page.pointee.rows.lastrow) + 1, columns = Int(page.pointee.rows.lastcol) + 1
            for row in 0..<rowCount {
                try token.check()
                try autoreleasepool {
                    var values = [String](repeating: "", count: columns)
                    for col in 0..<columns {
                        guard let c = xls_cell(page, UInt16(row), UInt16(col)) else { continue }
                        let cell = c.pointee
                        let formatID = Int(cell.xf) < Int(book.pointee.xfs.count) ? Int(book.pointee.xfs.xf[Int(cell.xf)].format) : 0
                        let numeric = cell.id == XLS_RECORD_RK || cell.id == XLS_RECORD_MULRK || cell.id == XLS_RECORD_NUMBER
                        let formula = cell.id == XLS_RECORD_FORMULA || cell.id == XLS_RECORD_FORMULA_ALT
                        if formula { result.formulaCount += 1 }
                        if numeric || (formula && cell.l == 0) {
                            values[col] = excelNumber(String(format: "%.15g", cell.d), formatID: formatID, custom: custom[formatID], date1904: date1904)
                        } else if let string = cell.str {
                            let text = String(cString: string)
                            if (formula || cell.id == XLS_RECORD_BOOLERR) && text == "bool" { values[col] = cell.d == 0 ? "FALSE" : "TRUE" }
                            else if (formula || cell.id == XLS_RECORD_BOOLERR) && text == "error" { values[col] = "#ERROR!" }
                            else { values[col] = text }
                        } else if formula { values[col] = "[Формула: нет сохранённого результата]"; result.missingFormulaCount += 1 }
                    }
                    try spool.row(row + 1, values)
                }
                if row % 256 == 0 { progress("Чтение XLS: \(row + 1) строк", Double(row + 1) / Double(rowCount) * 0.8) }
            }
        } else {
            let zip = try ExcelZip(source, scratch: result.folder, token: token)
            // Discover the workbook path again to resolve shared strings and styles.
            var workbookPath = "xl/workbook.xml"
            try parseXML(zip.extract("_rels/.rels", limit: 16 << 20), token: token, start: { name, a in
                if name == "Relationship", a["Type"]?.hasSuffix("/officeDocument") == true, let target = a["Target"], a["TargetMode"] != "External" { workbookPath = try resolvePart(target, relativeTo: "") }
            })
            let rels = try zip.relationships(for: workbookPath)
            if let strings = rels.values.first(where: { $0.type.hasSuffix("/sharedStrings") }) {
                progress("Чтение строк Excel…", 0.05)
                let path = try zip.extract(strings.path)
                var index = 0, value = "", inItem = false, inText = false, phonetic = 0
                try parseXML(path, token: token, start: { name, _ in
                    if name == "si" { value = ""; inItem = true }
                    if name == "rPh" { phonetic += 1 }
                    if name == "t" && inItem && phonetic == 0 { inText = true }
                }, text: { text in if inText { value += text } }, end: { name in
                    if name == "t" { inText = false }
                    if name == "rPh" { phonetic -= 1 }
                    if name == "si" { try spool.string(index, value); index += 1; inItem = false }
                })
            }
            var formats: [Int: String] = [:], styles: [Int] = [], cellXfs = false
            if let style = rels.values.first(where: { $0.type.hasSuffix("/styles") }) {
                try parseXML(zip.extract(style.path, limit: 32 << 20), token: token, start: { name, a in
                    if name == "numFmt", let id = a["numFmtId"].flatMap(Int.init) { formats[id] = a["formatCode"] ?? "" }
                    if name == "cellXfs" { cellXfs = true }
                    if name == "xf" && cellXfs { styles.append(a["numFmtId"].flatMap(Int.init) ?? 0) }
                }, end: { if $0 == "cellXfs" { cellXfs = false } })
            }
            progress("Распаковка листа…", 0.15)
            let xml = try zip.extract(sheet.path)
            var rowNumber = 0, nextColumn = 0, column = 0, styleIndex = 0, type = "", value = ""
            var values: [String] = [], inCell = false, inValue = false, inText = false, hasValue = false, formula = false, phonetic = 0
            var lastProgress = Date()
            try parseXML(xml, token: token, start: { name, a in
                switch name {
                case "row":
                    let next = a["r"].flatMap(Int.init) ?? rowNumber + 1
                    guard next > rowNumber, next <= 1_048_576 else { throw ScopeError("Некорректный номер строки XLSX.") }
                    rowNumber = next; nextColumn = 0; values = []
                case "c":
                    inCell = true; column = try a["r"].map { try excelColumn($0) } ?? nextColumn
                    guard column >= nextColumn, column < 16_384, rowNumber > 0 else { throw ScopeError("Некорректная колонка XLSX.") }
                    nextColumn = column + 1; type = a["t"] ?? "n"; styleIndex = a["s"].flatMap(Int.init) ?? 0
                    value = ""; hasValue = false; formula = false
                case "v": if inCell { inValue = true; hasValue = true }
                case "f": if inCell { formula = true }
                case "rPh": phonetic += 1
                case "t": if inCell && type == "inlineStr" && phonetic == 0 { inText = true; hasValue = true }
                default: break
                }
            }, text: { text in if inValue || inText { value += text } }, end: { name in
                switch name {
                case "v": inValue = false
                case "t": inText = false
                case "rPh": phonetic -= 1
                case "c":
                    var content = value
                    if formula { result.formulaCount += 1 }
                    if formula && !hasValue { content = "[Формула: нет сохранённого результата]"; result.missingFormulaCount += 1 }
                    else if type == "s" {
                        guard let index = Int(value) else { throw ScopeError("Некорректная ссылка на строку XLSX.") }
                        content = try spool.lookupString(index)
                    } else if type == "b" { content = value == "1" ? "TRUE" : "FALSE" }
                    else if type == "n" || type.isEmpty {
                        let id = styles.indices.contains(styleIndex) ? styles[styleIndex] : 0
                        content = excelNumber(value, formatID: id, custom: formats[id], date1904: date1904)
                    }
                    if !content.isEmpty {
                        if values.count <= column { values.append(contentsOf: repeatElement("", count: column + 1 - values.count)) }
                        values[column] = content
                    }
                    inCell = false
                case "row":
                    try spool.row(rowNumber, values)
                    if Date().timeIntervalSince(lastProgress) > 0.25 { progress("Чтение XLSX: \(rowNumber) строк", 0.5); lastProgress = Date() }
                default: break
                }
            })
        }
        progress("Подготовка таблицы…", 0.85)
        result.headerRow = try spool.writeCSV(result.csv, token: token)
        try token.check(); try validate()
        for file in try FileManager.default.contentsOfDirectory(at: result.folder, includingPropertiesForKeys: nil) where file.lastPathComponent != result.csv.lastPathComponent { try FileManager.default.removeItem(at: file) }
        progress("Лист готов", 1)
        return result
    }
    private static func openXLS(_ source: URL) throws -> UnsafeMutablePointer<xlsWorkBook> {
        var error = LIBXLS_OK
        guard let book = source.path.withCString({ xls_open_file($0, "UTF-8", &error) }) else {
            if error == LIBXLS_ERROR_UNSUPPORTED_ENCRYPTION { throw ScopeError("XLS защищён паролем. Сохраните незашифрованную копию в Excel.") }
            throw ScopeError("Не удалось прочитать XLS: " + String(cString: xls_getError(error)))
        }
        return book
    }
}

public final class ExcelImportResult: @unchecked Sendable {
    public let folder: URL
    public let csv: URL
    fileprivate var sourceFingerprint: Fingerprint?
    public fileprivate(set) var headerRow = 1
    public fileprivate(set) var formulaCount = 0
    public fileprivate(set) var missingFormulaCount = 0
    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("jsonic-excel-\(UUID().uuidString)", isDirectory: true)
        csv = folder.appendingPathComponent("sheet.csv")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? FileManager.default.removeItem(at: folder) }
    public func store(original: URL) throws -> CSVStore {
        guard try Fingerprint.read(original) == sourceFingerprint else { throw ScopeError("Книга Excel изменилась во время импорта.") }
        let store = try CSVStore(source: csv, format: CSVFormat(), cacheRoot: folder.appendingPathComponent("index"), originalSource: original, retaining: self)
        try store.validate()
        return store
    }
}

private final class ExcelSpool {
    let db: DB, putRow: Statement, putString: Statement, getString: Statement
    let token: Cancellation
    var width = 0
    init(folder: URL, token: Cancellation) throws {
        self.token = token; db = try DB(folder.appendingPathComponent("spool.sqlite")); db.interruptible(token)
        try db.exec("PRAGMA journal_mode=OFF; PRAGMA cache_size=-2048; CREATE TABLE rows (id INTEGER PRIMARY KEY, cells TEXT); CREATE TABLE strings (id INTEGER PRIMARY KEY, value TEXT); BEGIN")
        putRow = try db.statement("INSERT INTO rows VALUES (?,?)"); putString = try db.statement("INSERT INTO strings VALUES (?,?)"); getString = try db.statement("SELECT value FROM strings WHERE id=?")
    }
    func row(_ number: Int, _ input: [String]) throws {
        try token.check()
        guard let last = input.lastIndex(where: { !$0.isEmpty }) else { return }
        let values = Array(input[...last]); width = max(width, values.count)
        putRow.reset(); putRow.integer(1, Int64(number)); putRow.text(2, String(decoding: try JSONEncoder().encode(values), as: UTF8.self)); _ = try putRow.step()
    }
    func string(_ id: Int, _ value: String) throws {
        putString.reset(); putString.integer(1, Int64(id)); putString.text(2, value); _ = try putString.step()
    }
    func lookupString(_ id: Int) throws -> String {
        getString.reset(); getString.integer(1, Int64(id)); guard try getString.step() else { throw ScopeError("В XLSX отсутствует строка \(id).") }; return getString.string(0)
    }
    func writeCSV(_ url: URL, token: Cancellation) throws -> Int {
        try token.check(); try db.exec("COMMIT")
        guard width > 0 else { throw ScopeError("Выбранный лист пуст.") }
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ScopeError("Не удалось создать кеш листа Excel. Проверьте свободное место.") }
        let out = try FileHandle(forWritingTo: url); defer { try? out.close() }
        let rows = try db.statement("SELECT id,cells FROM rows ORDER BY id")
        var previous = 0, header = 0
        let blank = [String](repeating: "", count: width)
        while try rows.step() {
            try autoreleasepool {
                try token.check()
                let number = Int(rows.int(0))
                if previous > 0 { for _ in (previous + 1)..<number { try token.check(); try out.write(contentsOf: csvLine(blank, delimiter: 44)) } }
                var values = try JSONDecoder().decode([String].self, from: Data(rows.string(1).utf8))
                values.append(contentsOf: repeatElement("", count: width - values.count))
                if header == 0 {
                    header = number
                    for i in values.indices where values[i].isEmpty { values[i] = "Колонка \(i + 1)" }
                }
                try out.write(contentsOf: csvLine(values, delimiter: 44)); previous = number
            }
        }
        try out.synchronize(); return header
    }
}

private struct ExcelRelation { let type: String; let path: String }
private final class ExcelZip {
    let archive: Archive, scratch: URL, token: Cancellation
    var total: UInt64 = 0
    init(_ source: URL, scratch: URL, token: Cancellation) throws {
        self.scratch = scratch; self.token = token
        do { archive = try Archive(url: source, accessMode: .read) }
        catch { throw ScopeError("Не удалось открыть XLSX. Файл повреждён, защищён паролем или имеет другой формат.") }
    }
    func extract(_ path: String, limit: UInt64 = 4 << 30) throws -> URL {
        try token.check()
        guard let entry = archive[path], entry.type == .file, entry.uncompressedSize <= limit, total + entry.uncompressedSize <= 8 << 30 else { throw ScopeError("Недоступна часть XLSX или превышен лимит распаковки: \(path)") }
        let url = scratch.appendingPathComponent(UUID().uuidString + ".xml")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ScopeError("Не удалось создать кеш XLSX.") }
        let out = try FileHandle(forWritingTo: url); defer { try? out.close() }
        var count: UInt64 = 0
        let checksum = try archive.extract(entry, bufferSize: 65536) { bytes in
            try self.token.check(); count += UInt64(bytes.count)
            guard count <= limit && self.total + count <= 8 << 30 else { throw ScopeError("Превышен лимит распаковки XLSX.") }
            try out.write(contentsOf: bytes)
        }
        guard checksum == entry.checksum else { throw ScopeError("Ошибка контрольной суммы XLSX.") }
        total += count
        return url
    }
    func relationships(for path: String) throws -> [String: ExcelRelation] {
        let file = (path as NSString).lastPathComponent, dir = (path as NSString).deletingLastPathComponent
        let relPath = (dir.isEmpty ? "" : dir + "/") + "_rels/" + file + ".rels"
        var result: [String: ExcelRelation] = [:]
        try parseXML(extract(relPath, limit: 16 << 20), token: token, start: { name, a in
            if name == "Relationship", a["TargetMode"] != "External", let id = a["Id"], let target = a["Target"], let type = a["Type"] { result[id] = ExcelRelation(type: type, path: try resolvePart(target, relativeTo: dir)) }
        })
        return result
    }
}
private func resolvePart(_ target: String, relativeTo dir: String) throws -> String {
    guard !target.contains(":"), !target.contains("\\") else { throw ScopeError("Недопустимая ссылка внутри XLSX.") }
    var parts = target.hasPrefix("/") ? [] : dir.split(separator: "/").map(String.init)
    for part in (target.removingPercentEncoding ?? target).split(separator: "/") {
        if part == "." { continue }
        if part == ".." { guard !parts.isEmpty else { throw ScopeError("Некорректный путь XLSX.") }; parts.removeLast() }
        else { parts.append(String(part)) }
    }
    return parts.joined(separator: "/")
}
private final class ExcelXML: NSObject, XMLParserDelegate {
    let token: Cancellation
    let start: (String, [String: String]) throws -> Void, text: (String) throws -> Void, end: (String) throws -> Void
    var failure: Error?
    init(_ token: Cancellation, start: @escaping (String,[String:String]) throws -> Void, text: @escaping (String) throws -> Void, end: @escaping (String) throws -> Void) { self.token = token; self.start = start; self.text = text; self.end = end }
    func run(_ parser: XMLParser, _ action: () throws -> Void) {
        guard failure == nil else { return }
        do { try token.check(); try action() } catch { failure = error; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) { run(parser) { try start(elementName.components(separatedBy: ":").last!, attributes) } }
    func parser(_ parser: XMLParser, foundCharacters string: String) { run(parser) { try text(string) } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) { run(parser) { try end(elementName.components(separatedBy: ":").last!) } }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { run(parser) { throw ScopeError("XML-сущности DTD в XLSX не поддерживаются.") } }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { run(parser) { throw ScopeError("Внешние XML-сущности в XLSX не поддерживаются.") } }
}
private func parseXML(_ url: URL, token: Cancellation, start: @escaping (String,[String:String]) throws -> Void = { _,_ in }, text: @escaping (String) throws -> Void = { _ in }, end: @escaping (String) throws -> Void = { _ in }) throws {
    try token.check()
    guard let stream = InputStream(url: url) else { throw ScopeError("Не удалось прочитать XML листа.") }
    let parser = XMLParser(stream: stream), handler = ExcelXML(token, start: start, text: text, end: end)
    parser.shouldResolveExternalEntities = false; parser.externalEntityResolvingPolicy = .never; parser.delegate = handler
    let parsed = parser.parse()
    if let error = handler.failure { throw error }
    try token.check()
    guard parsed else { throw ScopeError("Повреждён XML в книге Excel (строка \(parser.lineNumber)).") }
}
private func excelColumn(_ reference: String) throws -> Int {
    var index = 0
    for byte in reference.utf8 {
        guard byte >= 65 && byte <= 90 else { break }
        index = index * 26 + Int(byte - 64)
        guard index <= 16_384 else { throw ScopeError("Колонка XLSX за пределами листа.") }
    }
    guard index > 0 else { throw ScopeError("Некорректный адрес ячейки XLSX.") }
    return index - 1
}
private func excelNumber(_ raw: String, formatID: Int, custom: String?, date1904: Bool) -> String {
    guard let value = Double(raw), value.isFinite else { return raw }
    let code = (custom ?? "").replacingOccurrences(of: #""[^"]*"|\\.|\[(?!h+\]|m+\]|s+\])[^\]]*\]"#, with: "", options: .regularExpression).lowercased()
    let dateFormat = (14...22).contains(formatID) || (27...36).contains(formatID) || (45...47).contains(formatID) || (50...58).contains(formatID) || code.contains("yy") || code.contains("dd") || code.contains("hh") || code.contains("ss")
    if dateFormat {
        guard abs(value) <= 3_000_000 else { return raw }
        let hasTime = [18,19,20,21,22,45,46,47].contains(formatID) || code.contains("h") || code.contains("s")
        let timeOnly = [18,19,20,21,45,46,47].contains(formatID) || (hasTime && !code.contains("y") && !code.contains("d") && formatID >= 164)
        if code.contains("[h]") || formatID == 46 {
            let seconds = Int64((value * 86400).rounded())
            return String(format: "%lld:%02lld:%02lld", seconds / 3600, abs(seconds / 60) % 60, abs(seconds) % 60)
        }
        let base = date1904 ? -2_082_844_800.0 : (value < 60 ? -2_209_075_200.0 : -2_209_161_600.0)
        let date = Date(timeIntervalSince1970: base + value * 86400)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = timeOnly ? "HH:mm:ss" : (hasTime ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd")
        if !date1904 && floor(value) == 60 && !timeOnly { return "1900-02-29" + (hasTime ? " " + String(formatter.string(from: date).suffix(8)) : "") }
        return formatter.string(from: date)
    }
    if let custom, !custom.isEmpty, custom.allSatisfy({ $0 == "0" }), custom.count <= 32, value >= 0, value.rounded() == value {
        let integer = String(format: "%.0f", value); return String(repeating: "0", count: max(0, custom.count - integer.count)) + integer
    }
    if formatID == 9 || formatID == 10 || code.hasSuffix("%") { return String(format: formatID == 9 ? "%.0f%%" : "%.2f%%", value * 100) }
    return raw
}

import Foundation
import Darwin
import JSONicCore

// All names, identifiers and credentials below are synthetic test values.
final class CoreTests {
    var folder: URL!
    func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("JSONic-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func fixture(_ rows: [[String]], delimiter: UInt8 = 44) throws -> CSVStore {
        let source = folder.appendingPathComponent("source.csv")
        var data = Data(); for row in rows { data.append(csvLine(row, delimiter: delimiter)) }
        try data.write(to: source)
        let store = try CSVStore(source: source, format: CSVFormat(delimiter: delimiter), cacheRoot: folder.appendingPathComponent("cache"))
        try store.build(Cancellation()) { _, _ in }; return store
    }
    func testSpreadsheetSafeExport() throws {
        let store = try fixture([["=header"], ["=1+1"], ["  +42"], ["plain"]])
        var request = ExportRequest(); request.rules.enabled = false
        let output = folder.appendingPathComponent("safe.csv")
        _ = try export(store, request: request, destination: output, token: Cancellation())
        let reader = try CSVReader(url: output, format: store.format)
        for expected in ["'=header", "'=1+1", "'  +42", "plain"] {
            XCTAssertEqual(try parse(XCTUnwrap(reader.next()).data, format: store.format), [expected])
        }
        request.protectSpreadsheetFormulas = false
        _ = try export(store, request: request, destination: output, token: Cancellation())
        XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: store.source))
        request.protectSpreadsheetFormulas = true
        request.scope = .cells; request.cells = [CellID(row: 1, column: 0)]; request.singleValue = true
        _ = try export(store, request: request, destination: output, token: Cancellation())
        XCTAssertEqual(try String(contentsOf: output), "=1+1")
    }
    func testCellEditing() throws {
        let store = try fixture([["message"], ["old needle"], ["other"]])
        let original = try Data(contentsOf: store.source)
        var request = ExportRequest(); request.rules.enabled = false
        try store.setCell(row: 1, column: 0, value: "new, \"value\"\nline")
        XCTAssertEqual(try store.readRow(1), ["new, \"value\"\nline"])
        XCTAssertTrue(try store.page(spec: SearchSpec(text: "needle"), token: Cancellation()).rows.isEmpty)
        XCTAssertEqual(try store.page(spec: SearchSpec(text: "value"), token: Cancellation()).rows.map(\.id), [1])
        let output = folder.appendingPathComponent("edited.csv")
        _ = try export(store, request: request, destination: output, token: Cancellation())
        let reader = try CSVReader(url: output, format: store.format); _ = try reader.next()
        XCTAssertEqual(try parse(XCTUnwrap(reader.next()).data, format: store.format), ["new, \"value\"\nline"])
        XCTAssertEqual(try Data(contentsOf: store.source), original)
        request.rules.enabled = true
        let analysis = try analyzeExport(store, request: request, token: Cancellation())
        try store.setCell(row: 2, column: 0, value: "changed")
        XCTAssertThrowsError(try analysis.validate(store: store, request: request))
    }
    func testExcelImport() throws {
        for ext in ["xls", "xlsx"] {
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sample." + ext)
            let local = folder.appendingPathComponent("book." + ext)
            try FileManager.default.copyItem(at: source, to: local)
            let book = try ExcelWorkbook.open(local, token: Cancellation())
            XCTAssertEqual(book.sheets.map(\.name), ["Логи", "Другой"])
            let imported = try book.importSheet(0, token: Cancellation())
            XCTAssertEqual(imported.headerRow, 2)
            let store = try imported.store(original: local)
            try store.build(Cancellation()) { _, _ in }
            let row = try store.readRow(1)
            if ext == "xls" {
                XCTAssertEqual(row, ["2026-11-12", "{\"phone\":\"+7 999 123-45-67\"}", "42"])
            } else {
                XCTAssertEqual(row, ["привет", "42"])
                XCTAssertEqual(imported.missingFormulaCount, 1)
            }
            XCTAssertTrue(try store.readRow(2).allSatisfy { $0.isEmpty })
            XCTAssertTrue(try store.readRow(3).contains("последняя"))
            XCTAssertEqual(try store.page(spec: SearchSpec(text: "последняя"), token: Cancellation()).rows.map(\.id), [3])
            XCTAssertThrowsError(try export(store, request: ExportRequest(), destination: local, token: Cancellation()))
            try Data("changed".utf8).write(to: local)
            XCTAssertThrowsError(try store.validate())
        }
    }
    func testCSVMultilineBoundaryAndEncoding() throws {
        let long = String(repeating: "я", count: 40000) + "\n\"цитата\";конец"
        let source = folder.appendingPathComponent("multiline.csv")
        var data = Data([239,187,191]); data.append(Data("a;b\r\n".utf8)); data.append(csvLine([long, ""], delimiter: 59))
        try data.write(to: source)
        let format = try CSVFormat.detect(source); XCTAssertEqual(format.delimiter, 59)
        let reader = try CSVReader(url: source, format: format)
        XCTAssertEqual(try parse(XCTUnwrap(reader.next()).data, format: format), ["a","b"])
        let row = try XCTUnwrap(reader.next()); XCTAssertEqual(row.offset, 8)
        XCTAssertEqual(try parse(row.data, format: format), [long, ""]); XCTAssertNil(try reader.next())
        let cp = folder.appendingPathComponent("cp.csv")
        try XCTUnwrap("имя;текст\r\nАнна;привет\r\n".data(using: .windowsCP1251)).write(to: cp)
        let detected = try CSVFormat.detect(cp); XCTAssertEqual(detected.encoding, .cp1251)
        let cpReader = try CSVReader(url: cp, format: detected); _ = try cpReader.next()
        XCTAssertEqual(try parse(XCTUnwrap(cpReader.next()).data, format: detected), ["Анна", "привет"])
    }
    func testSearchPagingCaseAndLiteralPunctuation() throws {
        var rows = [["id", "message"]]
        for i in 1...205 { rows.append([String(i), i == 103 ? "Скрытый JSON \"needle\": \"100%_ABC\"" : "обычный текст \(i)"]) }
        let store = try fixture(rows)
        let first = try store.page(spec: SearchSpec(), token: Cancellation()); XCTAssertEqual(first.rows.count, 100)
        let second = try store.page(spec: SearchSpec(), after: first.cursor, token: Cancellation()); XCTAssertEqual(second.rows.first?.id, 101)
        for query in ["СКРЫТЫЙ", "needle", "100%_", "\"needle\"", "ABC", "BC"] {
            XCTAssertEqual(try store.page(spec: SearchSpec(text: query), token: Cancellation()).rows.map(\.id), [103], query)
        }
        XCTAssertTrue(try store.page(spec: SearchSpec(text: "abc", caseSensitive: true), token: Cancellation()).rows.isEmpty)
        XCTAssertTrue(try store.page(spec: SearchSpec(text: "needle", columns: [0]), token: Cancellation()).rows.isEmpty)
        let reopened = try CSVStore(source: store.source, format: store.format, cacheRoot: folder.appendingPathComponent("cache"))
        XCTAssertTrue(try reopened.status().complete)
    }
    func testSelectedCellsMaskedAndNestedJSON() throws {
        let nested = #"{"name":"Анна","phone":"8 (999) 123-45-67"}"#
        let object: [String: Any] = ["name":"Анна", "phone":"+7 999 123 45 67", "payload":nested, "msg":"Анне позвонить +7 (999) 123-45-67"]
        let json = String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        let store = try fixture([["logDate","message","secret"], ["date",json,"DO_NOT_EXPORT"], ["date2","Анна","OTHER_SECRET"]])
        var request = ExportRequest(); request.scope = .cells; request.cells = [CellID(row: 2,column: 1),CellID(row: 1,column: 1)]
        request.rules.keys = ["name":.person,"phone":.phone]; request.rules.names = [["Анна","Анне"]]
        let output = folder.appendingPathComponent("cells.csv")
        let preview = try export(store, request: request, destination: nil, token: Cancellation())
        let report = try export(store, request: request, destination: output, token: Cancellation())
        XCTAssertEqual(report.replacements, preview.replacements); XCTAssertEqual(report.records, 2)
        let text = try String(contentsOf: output); XCTAssertFalse(text.contains("SECRET")); XCTAssertFalse(text.contains("999")); XCTAssertFalse(text.contains("Анн"))
        let reader = try CSVReader(url: output, format: store.format); _ = try reader.next()
        let fields = try parse(XCTUnwrap(reader.next()).data, format: store.format)
        XCTAssertEqual(Array(fields.prefix(2)),["1","message"])
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fields[2].utf8)) as? [String: Any])
        XCTAssertEqual(result["name"] as? String, "PERSON_001"); XCTAssertEqual(result["phone"] as? String, "PHONE_001")
        let inner = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((result["payload"] as! String).utf8)) as? [String:String])
        XCTAssertEqual(inner["phone"], "PHONE_001")
        XCTAssertEqual(try parse(XCTUnwrap(reader.next()).data, format: store.format), ["2","message","PERSON_001"])
    }
    func testExportScopesSingleValueAndMalformedJSON() throws {
        let store = try fixture([["id","message"],["a",#"{"x":1}"#],["b","{broken Анна +79991234567"]])
        var request = ExportRequest(); request.scope = .results; request.search = SearchSpec(text:"broken"); request.rules.enabled = false
        let output = folder.appendingPathComponent("result.csv")
        XCTAssertEqual(try export(store, request: request, destination: output, token: Cancellation()).records,1)
        request.scope = .rows; request.rows = [1]; XCTAssertEqual(try export(store, request: request, destination: output, token: Cancellation()).records,1)
        request.scope = .cells; request.cells = [CellID(row:1,column:1)]; request.singleValue = true
        let report = try export(store, request: request, destination: output, token: Cancellation())
        XCTAssertEqual(report.singleValueIsJSON, true); XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(contentsOf: output)))
        request.cells = [CellID(row:2,column:1)]; request.rules.enabled = true; request.rules.keys = ["name":.person]; request.rules.names = [["Анна"]]
        let malformed = try export(store, request: request, destination: output, token: Cancellation())
        XCTAssertEqual(malformed.malformedJSON,1); XCTAssertEqual(malformed.singleValueIsJSON,false)
        XCTAssertFalse(try String(contentsOf: output).contains("999"))
    }
    func testJSONInsideLog() throws {
        let prefix = "[2026-11-04] [demo-service] [info] Incoming HTTP-response: "
        let json = #"{"name":"Анна","phone":"+79991234567","text":"brace } and escaped \"quote\"","items":[1,2]}"#
        let input = prefix + json + " trailing text"
        let envelope = try XCTUnwrap(extractJSON(input))
        XCTAssertEqual(envelope.prefix, prefix)
        XCTAssertEqual(envelope.suffix, " trailing text")
        XCTAssertEqual((envelope.value as? [String: Any])?["name"] as? String, "Анна")
        XCTAssertNil(try extractJSON("[info] no JSON"))
        XCTAssertNil(try extractJSON("[info] {\"broken\":1"))
        let store = try fixture([["message"], [input]])
        var request = ExportRequest(); request.rules.keys = ["name": .person, "phone": .phone]
        let out = folder.appendingPathComponent("masked-log.csv")
        let report = try export(store, request: request, destination: out, token: Cancellation())
        XCTAssertEqual(report.replacements, 2)
        let reader = try CSVReader(url: out, format: store.format); _ = try reader.next()
        let masked = try parse(XCTUnwrap(reader.next()).data, format: store.format)[0]
        XCTAssertTrue(masked.hasPrefix(prefix)); XCTAssertTrue(masked.hasSuffix(" trailing text"))
        XCTAssertFalse(masked.contains("Анна")); XCTAssertFalse(masked.contains("999"))
        XCTAssertNotNil(try extractJSON(masked))
    }
    func testAutomaticMasking() throws {
        let json = #"{"id":"79130000000","numeric":79130000000,"again":"+7 (913) 000-00-00","name":"Пример Сервис","first_name":"Зульфия","date":"2026-11-11","counter":104857600,"msg":"Анна Ивановна Иванова позвонила Сергею Петровичу Петрову. Меня зовут Зульфия Ахметова."}"#
        let store = try fixture([["message"], ["[info] response: " + json]])
        var request = ExportRequest()
        let out = folder.appendingPathComponent("auto.csv")
        let report = try export(store, request: request, destination: out, token: Cancellation())
        let reader = try CSVReader(url: out, format: store.format); _ = try reader.next()
        let value = try parse(XCTUnwrap(reader.next()).data, format: store.format)[0]
        let object = try XCTUnwrap(extractJSON(value)?.value as? [String: Any])
        XCTAssertEqual(object["id"] as? String, object["numeric"] as? String)
        XCTAssertEqual(object["id"] as? String, object["again"] as? String)
        XCTAssertEqual(object["name"] as? String, "Пример Сервис")
        XCTAssertEqual(object["counter"] as? Int, 104857600)
        XCTAssertEqual(object["date"] as? String, "2026-11-11")
        XCTAssertFalse(value.contains("79130000000")); XCTAssertFalse(value.contains("Анна")); XCTAssertFalse(value.contains("Иванова"))
        XCTAssertFalse(value.contains("Сергею")); XCTAssertFalse(value.contains("Петрову")); XCTAssertFalse(value.contains("Зульфия"))
        let candidate = try XCTUnwrap(report.examples.first { $0.original.contains("913") })
        request.rules.excluded = [candidate.identity]
        let excluded = try export(store, request: request, destination: out, token: Cancellation())
        XCTAssertEqual(excluded.skipped, 3)
        let second = try CSVReader(url: out, format: store.format); _ = try second.next()
        let unmasked = try parse(XCTUnwrap(second.next()).data, format: store.format)[0]
        let restored = try XCTUnwrap(extractJSON(unmasked)?.value as? [String: Any])
        XCTAssertEqual(restored["numeric"] as? Int64, 79130000000)
        XCTAssertEqual(restored["id"] as? String, "79130000000")
        request.rules.enabled = false
        _ = try export(store, request: request, destination: out, token: Cancellation())
        let original = try CSVReader(url: out, format: store.format); _ = try original.next()
        XCTAssertEqual(try parse(XCTUnwrap(original.next()).data, format: store.format)[0], "[info] response: " + json)
    }
    func testCancellationAndSourceProtection() throws {
        let store = try fixture([["a"],["x"],["y"]])
        XCTAssertThrowsError(try export(store, request: ExportRequest(), destination: store.source, token: Cancellation()))
        let out = folder.appendingPathComponent("out.csv"); try Data("existing".utf8).write(to: out)
        let token = Cancellation(); token.cancel()
        XCTAssertThrowsError(try export(store, request: ExportRequest(), destination: out, token: token))
        XCTAssertEqual(try String(contentsOf: out),"existing")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasSuffix(".tmp") })
        try Data("a\nchanged\n".utf8).write(to: store.source)
        XCTAssertThrowsError(try store.validate())
    }
    func testConservativeAnalysis() throws {
        let plain = ["SC", "0123456789abcdef0123456789abcdef", "Methods", "Httponly", "API", "Type", "UUID", "Gen", "Example", "GMT", "Анна", "Сергей Петров", "Большая Новая Компания", "Проверить Этот Сервис", "[INFO] ready", "[2026-11-12 12:34:56] [service] OK"]
        let fio = ["Иванов Иван Иванович", "Иван Иванович Иванов", "Иванову Ивану Ивановичу", "Анне Петровне Ивановой", "Петрова Анна Сергеевна", "Петрова Анна Ильинична", "Иван Лукич Петров", "Салтыков-Щедрин Михаил Евграфович", "Меня зовут Зульфия Ахметова"]
        let store = try fixture([["message"]] + plain.map { [$0] } + fio.map { [$0] } + [["[info] {\"phone\":\"79130000000\""], ["79130000000"]])
        let request = ExportRequest()
        let analysis = try analyzeExport(store, request: request, token: Cancellation())
        let report = try analysis.report()
        XCTAssertEqual(report.malformedJSON, 1)
        XCTAssertEqual(report.issues.first?.row, Int64(plain.count + fio.count + 1))
        XCTAssertEqual(report.replacements, Int64(fio.count + 2))
        let out = folder.appendingPathComponent("conservative.csv")
        _ = try export(store, request: request, destination: out, token: Cancellation(), analysis: analysis)
        let reader = try CSVReader(url: out, format: store.format); _ = try reader.next()
        for value in plain { XCTAssertEqual(try parse(XCTUnwrap(reader.next()).data, format: store.format)[0], value) }
        for _ in fio { XCTAssertTrue(try parse(XCTUnwrap(reader.next()).data, format: store.format)[0].contains("PERSON_")) }
        let technical = try fixture([["message"], [#"{"firstName":{"code":"SC"},"lastName":"Иванов","name":"Methods","method":"GMT"}"#]])
        let technicalReport = try analyzeExport(technical, request: request, token: Cancellation()).report()
        XCTAssertEqual(technicalReport.replacements, 1)
        XCTAssertEqual(technicalReport.examples.first?.original, "Иванов")
    }
    func testPreparedAnalysisLifecycle() throws {
        let nested = #"{"numeric":79130000000,"msg":"позвонить 8 (913) 000-00-00"}"#
        let object: [String: Any] = ["payload": nested, "id": "79130000000", "keep": "Methods"]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]), as: UTF8.self)
        let store = try fixture([["message", "other"], [json, "SECRET"], ["79130000000", "SECRET2"]])
        var request = ExportRequest(); request.scope = .cells; request.cells = [CellID(row: 1, column: 0), CellID(row: 2, column: 0)]
        let temp = FileManager.default.temporaryDirectory
        func indexes() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: temp.path).filter { $0.hasPrefix("jsonic-analysis-") }) }
        let before = try indexes()
        var analysis: MaskAnalysis? = try analyzeExport(store, request: request, token: Cancellation())
        XCTAssertEqual(try indexes().subtracting(before).count, 1)
        let report = try XCTUnwrap(analysis).report()
        XCTAssertEqual(report.replacements, 4); XCTAssertEqual(report.exampleCount, 1)
        let id = try XCTUnwrap(report.examples.first).identity
        request.rules.excluded = [id]
        let excluded = try XCTUnwrap(analysis).report(excluded: request.rules.excluded)
        XCTAssertEqual(excluded.replacements, 0); XCTAssertEqual(excluded.skipped, 4)
        let out = folder.appendingPathComponent("prepared.csv")
        _ = try export(store, request: request, destination: out, token: Cancellation(), analysis: analysis)
        let reader = try CSVReader(url: out, format: store.format); _ = try reader.next()
        XCTAssertEqual(try parse(XCTUnwrap(reader.next()).data, format: store.format), ["1", "message", json])
        XCTAssertEqual(try parse(XCTUnwrap(reader.next()).data, format: store.format), ["2", "message", "79130000000"])
        request.rules.excluded = []
        _ = try export(store, request: request, destination: out, token: Cancellation(), analysis: analysis)
        let masked = try String(contentsOf: out)
        XCTAssertFalse(masked.contains("SECRET")); XCTAssertFalse(masked.contains("7913")); XCTAssertTrue(masked.contains("Methods"))
        let saved = try Data(contentsOf: out)
        var changed = request; changed.rules.automaticNames = false
        XCTAssertThrowsError(try export(store, request: changed, destination: out, token: Cancellation(), analysis: analysis))
        changed = request; changed.cells = [CellID(row: 1, column: 0)]
        XCTAssertThrowsError(try export(store, request: changed, destination: out, token: Cancellation(), analysis: analysis))
        let cancelled = Cancellation(); cancelled.cancel()
        XCTAssertThrowsError(try export(store, request: request, destination: out, token: cancelled, analysis: analysis))
        XCTAssertEqual(try Data(contentsOf: out), saved)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix(".jsonic-") })
        let handle = try FileHandle(forWritingTo: store.source); try handle.seekToEnd(); try handle.write(contentsOf: Data("\n".utf8)); try handle.close()
        // Report paging/exclusions do not even read the source; saving still rejects changes.
        XCTAssertEqual(try XCTUnwrap(analysis).report(excluded: [id]).skipped, 4)
        XCTAssertThrowsError(try export(store, request: request, destination: out, token: Cancellation(), analysis: analysis))
        analysis = nil
        XCTAssertEqual(try indexes(), before)
        XCTAssertThrowsError(try analyzeExport(store, request: request, token: cancelled))
        XCTAssertEqual(try indexes(), before)
    }
    func testAnalysisPagesAndSingleValue() throws {
        let rows = (0..<165).map { [String(79130000000 + $0)] }
        let store = try fixture([["message"]] + rows)
        var request = ExportRequest()
        let analysis = try analyzeExport(store, request: request, token: Cancellation())
        let first = try analysis.report(), second = try analysis.report(offset: 80), third = try analysis.report(offset: 160)
        XCTAssertEqual(first.exampleCount, 165); XCTAssertEqual(first.examples.count, 80)
        XCTAssertEqual(second.examples.count, 80); XCTAssertEqual(third.examples.count, 5)
        XCTAssertEqual(Set((first.examples + second.examples + third.examples).map(\.identity)).count, 165)
        request.scope = .cells; request.cells = [CellID(row: 1, column: 0)]
        let single = try analyzeExport(store, request: request, token: Cancellation())
        let report = try single.report(); XCTAssertEqual(report.singleValueIsJSON, false)
        request.singleValue = true
        let out = folder.appendingPathComponent("single.txt")
        _ = try export(store, request: request, destination: out, token: Cancellation(), analysis: single)
        XCTAssertEqual(try String(contentsOf: out), "PHONE_001")
        request.rules.excluded = [try XCTUnwrap(report.examples.first).identity]
        XCTAssertEqual(try single.report(excluded: request.rules.excluded).singleValueIsJSON, true)
        let raw = try export(store, request: request, destination: out, token: Cancellation(), analysis: single)
        XCTAssertEqual(raw.singleValueIsJSON, true)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: out), options: [.fragmentsAllowed]) as? Int64, 79130000000)
        let jsonStore = try fixture([["message"], [#"{"id":"79130000000","unchanged":"Methods"}"#]])
        request.rules.excluded = []
        let jsonAnalysis = try analyzeExport(jsonStore, request: request, token: Cancellation())
        XCTAssertEqual(try jsonAnalysis.report().singleValueIsJSON, true)
        _ = try export(jsonStore, request: request, destination: out, token: Cancellation(), analysis: jsonAnalysis)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: String])
        XCTAssertEqual(json["id"], "PHONE_001"); XCTAssertEqual(json["unchanged"], "Methods")
    }
    func testStructuredMasking() throws {
        let object: [String: Any] = [
            "email": "User+tag@example.org", "telegram": "@sample_user", "login": "MixedCase",
            "inn": "7707083893", "snils": "11223344595", "passport": "45 10 123456",
            "address": ["city": "Москва", "street": "Ленина", "house": 10],
            "password": "SecretCase", "access_token": "secretcase", "Authorization": "Bearer test.credential",
            "payload": #"{"email":"User+tag@EXAMPLE.ORG","username":"MixedCase","snils":"112-233-445 95","inn":"123","passport":{"series":"4510","number":"123456"}}"#,
            "other": "Methods", "ip": "2001:db8::1", "server": ["address": "192.168.1.1"]
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let text = "email=User+tag@example.org; Telegram:@sample_user; https://t.me/sample_user; логин: MixedCase; ИНН 7707083893; СНИЛС 112-233-445 95; паспорт 45 10 123456; г. Москва, ул. Ленина, д. 10, кв. 2; password=SecretCase; Authorization: Bearer test.credential"
        let store = try fixture([["message"], [json], [text], ["[INFO] Cookie: session=abc; auth=def"]])
        let request = ExportRequest()
        let analysis = try analyzeExport(store, request: request, token: Cancellation())
        let report = try analysis.report()
        for kind in MaskKind.defaultAdditional { XCTAssertTrue(report.examples.contains { $0.replacement.hasPrefix(kind.rawValue + "_") }) }
        XCTAssertFalse(report.examples.contains { $0.replacement.hasPrefix("IP_") })
        XCTAssertFalse(report.examples.contains { $0.original == "192.168.1.1" })
        let out = folder.appendingPathComponent("structured.csv")
        _ = try export(store, request: request, destination: out, token: Cancellation(), analysis: analysis)
        let reader = try CSVReader(url: out, format: store.format); _ = try reader.next()
        let first = try parse(XCTUnwrap(reader.next()).data, format: store.format)[0]
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
        XCTAssertEqual(value["other"] as? String, "Methods"); XCTAssertEqual(value["ip"] as? String, "2001:db8::1")
        let inner = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((value["payload"] as! String).utf8)) as? [String: Any])
        XCTAssertEqual(value["email"] as? String, inner["email"] as? String)
        XCTAssertEqual(value["login"] as? String, inner["username"] as? String)
        XCTAssertEqual(value["snils"] as? String, inner["snils"] as? String)
        XCTAssertTrue((inner["inn"] as? String)?.hasPrefix("INN_") == true) // invalid but explicit field
        XCTAssertFalse((value["password"] as? String) == (value["access_token"] as? String)) // credentials are case-sensitive
        let second = try parse(XCTUnwrap(reader.next()).data, format: store.format)[0]
        for key in ["email", "telegram", "login", "inn", "snils", "passport", "password"] { XCTAssertTrue(second.contains(value[key] as! String)) }
        XCTAssertTrue(second.hasPrefix("email=EMAIL_")); XCTAssertFalse(second.contains("Ленина")); XCTAssertFalse(second.contains("test.credential"))
        XCTAssertFalse(try parse(XCTUnwrap(reader.next()).data, format: store.format)[0].contains("auth=def"))
        var excludedRequest = request
        excludedRequest.rules.excluded = [try XCTUnwrap(report.examples.first { $0.replacement == value["snils"] as? String }).identity]
        _ = try export(store, request: excludedRequest, destination: out, token: Cancellation(), analysis: analysis)
        let unmasked = try String(contentsOf: out)
        XCTAssertTrue(unmasked.contains("11223344595")); XCTAssertTrue(unmasked.contains("112-233-445 95"))
        var changed = request; changed.rules.additionalTypes.remove(.email)
        XCTAssertThrowsError(try export(store, request: changed, destination: out, token: Cancellation(), analysis: analysis))
    }
    func testStructuredBoundariesAndFlags() throws {
        let plain = "SC Methods GMT Httponly 0123456789abcdef0123456789abcdef @sample_user User loginMethod=Methods counter=7707083893 id=11223344595 000-000-000 00 ИННовации 7707083893 999.999.999.999 12:34:56"
        let store = try fixture([["message"], [plain], ["IPv4: 192.168.1.1. IPv6: [2001:0db8:0:0:0:0:0:1] / 2001:db8::1."], [#"{"email":"79130000000@example.org","username":"79130000000","token":"79130000000","snils":"79130000000"}"#]])
        var request = ExportRequest(); request.rules.additionalTypes = [.ip]
        let analysis = try analyzeExport(store, request: request, token: Cancellation())
        let report = try analysis.report()
        XCTAssertEqual(report.replacements, 3); XCTAssertEqual(report.exampleCount, 2)
        let out = folder.appendingPathComponent("flags.csv")
        _ = try export(store, request: request, destination: out, token: Cancellation(), analysis: analysis)
        let reader = try CSVReader(url: out, format: store.format); _ = try reader.next()
        XCTAssertEqual(try parse(XCTUnwrap(reader.next()).data, format: store.format)[0], plain)
        let ips = try parse(XCTUnwrap(reader.next()).data, format: store.format)[0]
        XCTAssertFalse(ips.contains("192.168")); XCTAssertFalse(ips.contains("2001:"))
        let disabled = try parse(XCTUnwrap(reader.next()).data, format: store.format)[0]
        XCTAssertTrue(disabled.contains("79130000000@example.org")); XCTAssertFalse(disabled.contains("PHONE_"))
        let malformed = try fixture([["message"], [#"[INFO] {"email":"test@example.org","password":"secret value","inn":"1234567890","telegram":"@sample_user""#]])
        let bad = try analyzeExport(malformed, request: ExportRequest(), token: Cancellation())
        let badReport = try bad.report()
        XCTAssertEqual(badReport.malformedJSON, 1)
        XCTAssertEqual(badReport.exampleCount, 4)
        _ = try export(malformed, request: ExportRequest(), destination: out, token: Cancellation(), analysis: bad)
        let masked = try String(contentsOf: out)
        XCTAssertFalse(masked.contains("test@example.org")); XCTAssertFalse(masked.contains("secret value")); XCTAssertFalse(masked.contains("1234567890")); XCTAssertFalse(masked.contains("@sample_user"))
    }
    func testTechnicalEmailAndNullLogin() throws {
        let actor = "example_actor_001@192.0.2.10"
        let plain = actor + " example_actor_002@192.0.2.10 (login=null) username=undefined; login=nil; login=none; user@example.123"
        let json = #"{"login":null,"username":"null","nested":"{\"username\":null}"}"#
        let valid = "email=person+tag@example.org; почта: имя@пример.рф; mail@xn--e1afmkfd.xn--p1ai; (login=real_user)"
        let store = try fixture([["message"], [plain], [json], [valid]])
        let request = ExportRequest()
        let analysis = try analyzeExport(store, request: request, token: Cancellation())
        let report = try analysis.report()
        XCTAssertEqual(report.exampleCount, 4)
        XCTAssertEqual(report.examples.filter { $0.replacement.hasPrefix("EMAIL_") }.count, 3)
        XCTAssertEqual(report.examples.first { $0.replacement.hasPrefix("LOGIN_") }?.original, "real_user")
        let out = folder.appendingPathComponent("false-positives.csv")
        _ = try export(store, request: request, destination: out, token: Cancellation(), analysis: analysis)
        let reader = try CSVReader(url: out, format: store.format); _ = try reader.next()
        XCTAssertEqual(try parse(XCTUnwrap(reader.next()).data, format: store.format)[0], plain)
        XCTAssertEqual(try parse(XCTUnwrap(reader.next()).data, format: store.format)[0], json)
        let masked = try parse(XCTUnwrap(reader.next()).data, format: store.format)[0]
        XCTAssertTrue(masked.contains("(login=LOGIN_001)"))
        var ip = request; ip.rules.additionalTypes.insert(.ip)
        let ipReport = try analyzeExport(store, request: ip, token: Cancellation()).report()
        XCTAssertEqual(ipReport.examples.filter { $0.replacement.hasPrefix("EMAIL_") }.count, 3)
        XCTAssertEqual(ipReport.examples.filter { $0.replacement.hasPrefix("IP_") }.count, 1)
    }
    func testOneGBIfRequested() throws {
        guard ProcessInfo.processInfo.environment["JSONIC_BENCH"] == "1" else { throw XCTSkip("Set JSONIC_BENCH=1 for 1 GB acceptance check") }
        let source = folder.appendingPathComponent("large.csv")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let h = try FileHandle(forWritingTo:source)
        try h.write(contentsOf: csvLine(["id","message"],delimiter:44))
        let payload = String(repeating:"abcdefghijklmnopqrstuvwxyz 0123456789 ",count:210)
        let recordCount = 130000
        for i in 1...recordCount { try h.write(contentsOf: csvLine([String(i),"{\"msg\":\"\(payload)\",\"id\":\(i)}"],delimiter:44)) }
        try h.close()
        let store = try CSVStore(source:source,format:CSVFormat(),cacheRoot:folder.appendingPathComponent("cache"))
        let start = Date(); var nextMark = 0.1
        try store.build(Cancellation()) { _, fraction in
            if fraction >= nextMark { print("BENCH index \(Int(fraction*100))%", terminator:"\n"); fflush(stdout); nextMark += 0.1 }
        }
        let indexTime = Date().timeIntervalSince(start)
        XCTAssertEqual(try store.status().count,Int64(recordCount)); XCTAssertGreaterThan(store.size,1_000_000_000)
        let searchStart = Date()
        XCTAssertEqual(try store.page(spec:SearchSpec(text:"\"id\":129999"),token:Cancellation()).rows.map(\.id),[129999])
        let searchTime = Date().timeIntervalSince(searchStart)
        var request = ExportRequest(); request.rules.enabled = false
        let out = folder.appendingPathComponent("copy.csv")
        let exportStart = Date(); let report = try export(store,request:request,destination:out,token:Cancellation())
        XCTAssertEqual(report.records,Int64(recordCount))
        let reader = try CSVReader(url:out,format:CSVFormat()); _ = try reader.next(); var rows = 0
        while let record = try reader.next() { rows += 1; if rows == recordCount { XCTAssertEqual(try parse(record.data,format:CSVFormat())[0],String(recordCount)) } }
        XCTAssertEqual(rows,recordCount)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("BENCH bytes=\(store.size) index_seconds=\(indexTime) search_seconds=\(searchTime) export_and_read_seconds=\(Date().timeIntervalSince(exportStart)) max_rss_bytes=\(usage.ru_maxrss)")
    }
}

var failures = 0
func fail(_ message: String) { failures += 1; print("FAIL: " + message) }
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "") { do { if try a() != b() { fail("Values differ " + message) } } catch { fail(error.localizedDescription) } }
func XCTAssertTrue(_ a: @autoclosure () throws -> Bool) { do { if try !a() { fail("Expected true") } } catch { fail(error.localizedDescription) } }
func XCTAssertFalse(_ a: @autoclosure () throws -> Bool) { do { if try a() { fail("Expected false") } } catch { fail(error.localizedDescription) } }
func XCTAssertGreaterThan<T: Comparable>(_ a: @autoclosure () throws -> T, _ b: T) { do { if try a() <= b { fail("Expected greater value") } } catch { fail(error.localizedDescription) } }
func XCTAssertNil<T>(_ a: @autoclosure () throws -> T?) { do { if try a() != nil { fail("Expected nil") } } catch { fail(error.localizedDescription) } }
func XCTAssertNotNil<T>(_ a: @autoclosure () throws -> T?) { do { if try a() == nil { fail("Expected non-nil") } } catch { fail(error.localizedDescription) } }
func XCTAssertThrowsError<T>(_ a: @autoclosure () throws -> T) { do { _ = try a(); fail("Expected error") } catch {} }
func XCTUnwrap<T>(_ a: T?) throws -> T { guard let a else { throw ScopeError("Unexpected nil") }; return a }
struct XCTSkip: Error { let message: String; init(_ message: String) { self.message = message } }
let tests = CoreTests()
let checks: [(String, () throws -> Void)] = [
    ("Spreadsheet-safe CSV export", tests.testSpreadsheetSafeExport),
    ("Cell editing", tests.testCellEditing),
    ("Excel import", tests.testExcelImport),
    ("CSV boundaries and encoding", tests.testCSVMultilineBoundaryAndEncoding),
    ("Search, pagination, cache", tests.testSearchPagingCaseAndLiteralPunctuation),
    ("Selected cells, masking, nested JSON", tests.testSelectedCellsMaskedAndNestedJSON),
    ("Export scopes and malformed JSON", tests.testExportScopesSingleValueAndMalformedJSON),
    ("Cancellation and source protection", tests.testCancellationAndSourceProtection),
    ("JSON inside log messages", tests.testJSONInsideLog),
    ("Automatic masking and exclusions", tests.testAutomaticMasking),
    ("Conservative analysis", tests.testConservativeAnalysis),
    ("Prepared analysis lifecycle", tests.testPreparedAnalysisLifecycle),
    ("Analysis paging and single values", tests.testAnalysisPagesAndSingleValue),
    ("Structured masking", tests.testStructuredMasking),
    ("Structured boundaries and flags", tests.testStructuredBoundariesAndFlags),
    ("Technical email and null login", tests.testTechnicalEmailAndNullLogin),
    ("1 GB acceptance", tests.testOneGBIfRequested)
]
for (name, check) in checks {
    if let filter = ProcessInfo.processInfo.environment["JSONIC_CHECK_FILTER"], !name.contains(filter) { continue }
    let before = failures
    do {
        try tests.setUpWithError()
        defer { try? tests.tearDownWithError() }
        try check()
        if before == failures { print("PASS: " + name) }
    } catch let skip as XCTSkip { print("SKIP: " + skip.message) }
    catch { fail(name + ": " + error.localizedDescription) }
    fflush(stdout)
}
exit(failures == 0 ? 0 : 1)

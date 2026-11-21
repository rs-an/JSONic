import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JSONicCore

@MainActor final class AppModel: ObservableObject {
    @Published var source: URL?
    @Published var workbook: ExcelWorkbook?
    @Published var showSheetPicker = false
    @Published var selectedSheet = 0
    @Published var sheetName: String?
    @Published var excelNote = ""
    @Published var headers: [String] = []
    @Published var wrapCells = false
    @Published var pageRevision = UUID()
    @Published var pageRows: [RowPreview] = []
    @Published var selectedRows: Set<Int64> = []
    @Published var selectedCells: Set<CellID> = []
    @Published var query = ""
    @Published var columns: Set<Int> = []
    @Published var caseSensitive = false
    @Published var delimiter: UInt8 = 44
    @Published var encoding: CSVEncoding = .utf8
    @Published var status = "Откройте CSV или Excel: данные останутся на вашем Mac"
    @Published var error: String?
    @Published var indexing = false
    @Published var complete = false
    @Published var progress = 0.0
    @Published var total: Int64 = 0
    @Published var found: Int64?
    @Published var searching = false
    @Published var exhausted = true
    @Published var pageNumber = 1
    @Published var detail: DetailData?
    @Published var detailLoading = false
    @Published var activeCell: CellID?
    @Published var showExport = false
    @Published var exporting = false
    @Published var exportStatus = ""
    @Published var exportReport: ExportReport?
    @Published var exportRequest: ExportRequest?
    private var exportAnalysis: MaskAnalysis?
    private var exportRun = UUID()
    var store: CSVStore?
    private var generation = UUID()
    private var searchID = UUID()
    private var detailID = UUID()
    private var indexToken = Cancellation(), searchToken = Cancellation(), detailToken = Cancellation(), countToken = Cancellation()
    private var exportToken = Cancellation()
    private var indexTask: Task<Void, Never>?, searchTask: Task<Void, Never>?, countTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var countSpec: SearchSpec?
    private var countRevision = -1
    private var cursor: Int64 = 0
    private var starts: [Int64] = [0]
    private var pendingTableMove: (direction: Int, column: Int?)?
    private var timer: Timer?
    var spec: SearchSpec { SearchSpec(text: query, columns: columns, caseSensitive: caseSensitive) }
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSource() }
        }
    }
    @Published var editingCell: CellID?
    @Published var editorText = ""
    @Published var editorOriginal = ""
    @Published var savingEdit = false
    @Published var editedCells: Set<CellID> = []
    func confirmDiscardEdits() -> Bool {
        guard !editedCells.isEmpty else { return true }
        let alert = NSAlert(); alert.messageText = "Отбросить правки?"
        alert.informativeText = "Правки есть только в приложении. Чтобы сохранить их, сначала экспортируйте копию нужных данных."
        alert.addButton(withTitle: "Остаться"); alert.addButton(withTitle: "Отбросить")
        return alert.runModal() == .alertSecondButtonReturn
    }
    func beginEditing(_ cell: CellID) {
        guard complete, !exporting, !showExport, editingCell == nil, let store else { return }
        Task {
            do {
                let value = try await Task.detached {
                    let values = try store.readRow(cell.row)
                    guard values.indices.contains(cell.column) else { throw ScopeError("Некорректная колонка.") }
                    return values[cell.column]
                }.value
                guard self.store === store, !exporting, !showExport, editingCell == nil else { return }
                editorText = value; editorOriginal = value; editingCell = cell
            } catch { self.error = error.localizedDescription }
        }
    }
    func applyEdit() {
        guard let cell = editingCell, let store, !savingEdit else { return }
        let value = editorText
        if value == editorOriginal { editingCell = nil; return }
        savingEdit = true
        Task {
            do {
                try await Task.detached { try store.setCell(row: cell.row, column: cell.column, value: value) }.value
                editedCells.insert(cell); exportAnalysis = nil; exportReport = nil
                editingCell = nil; savingEdit = false
                inspect(cell); search(reset: false, debounce: false)
            } catch { savingEdit = false; self.error = error.localizedDescription }
        }
    }
    private func resetDocumentState() {
        indexToken.cancel(); searchToken.cancel(); countToken.cancel(); detailToken.cancel()
        generation = UUID(); searchID = UUID(); detailID = UUID()
        countSpec = nil; found = nil; searching = false; pendingTableMove = nil
        headers = []; pageRows = []; selectedRows = []; selectedCells = []
        detail = nil; activeCell = nil; detailLoading = false
    }
    func pickFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText] + ["xls", "xlsx"].compactMap { UTType(filenameExtension: $0) }; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func open(_ url: URL, format: CSVFormat? = nil) {
        guard !exporting, editingCell == nil, confirmDiscardEdits() else { return }
        editedCells = []
        resetDocumentState()
        let previous = indexTask
        let gen = generation
        workbook = nil; showSheetPicker = false; sheetName = nil; excelNote = ""
        source = url; store = nil
        complete = false; indexing = true; progress = 0; total = 0; found = nil; error = nil
        status = "Открытие файла…"; starts = [0]; pageNumber = 1
        let token = Cancellation(); indexToken = token
        indexTask = Task.detached(priority: .userInitiated) { [weak self] in
            await previous?.value
            do {
                try token.check()
                if ExcelWorkbook.supports(url) {
                    let info = try ExcelWorkbook.open(url, token: token)
                    try token.check()
                    await self?.discoveredWorkbook(info, gen: gen)
                    return
                }
                let detected = try format ?? CSVFormat.detect(url)
                let store = try CSVStore(source: url, format: detected)
                try token.check()
                await self?.opened(store, gen: gen)
                try store.build(token) { count, fraction in
                    Task { @MainActor [weak self] in self?.indexed(count, fraction: fraction, gen: gen) }
                }
                await self?.finishedIndex(gen: gen)
            } catch is CancellationError { await self?.cancelledIndex(gen: gen) }
            catch { await self?.failedIndex(error, gen: gen) }
        }
    }
    private func discoveredWorkbook(_ info: ExcelWorkbook, gen: UUID) {
        guard generation == gen else { return }
        workbook = info; selectedSheet = info.sheets.first(where: { !$0.hidden })?.id ?? info.sheets[0].id
        indexing = false
        if info.sheets.count == 1 { openSelectedSheet() }
        else { status = "Выберите лист Excel"; showSheetPicker = true }
    }
    func openSelectedSheet() {
        guard let info = workbook, !exporting, editingCell == nil, confirmDiscardEdits() else { return }
        editedCells = []
        let sheet = selectedSheet
        showSheetPicker = false
        resetDocumentState()
        let previous = indexTask
        let gen = generation
        store = nil
        complete = false; indexing = true; searching = false; progress = 0; total = 0; found = nil; error = nil
        starts = [0]; pageNumber = 1; pendingTableMove = nil
        sheetName = info.sheets.first(where: { $0.id == sheet })?.name; excelNote = ""
        status = "Импорт Excel…"
        let token = Cancellation(); indexToken = token
        indexTask = Task.detached(priority: .userInitiated) { [weak self] in
            await previous?.value
            do {
                let imported = try info.importSheet(sheet, token: token) { message, fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == gen, self.store == nil else { return }
                        self.status = message; self.progress = fraction
                    }
                }
                try token.check()
                let store = try imported.store(original: info.source)
                await self?.importedExcel(imported, store: store, gen: gen)
                try store.build(token) { count, fraction in
                    Task { @MainActor [weak self] in self?.indexed(count, fraction: fraction, gen: gen) }
                }
                try token.check()
                await self?.finishedIndex(gen: gen)
            } catch is CancellationError { await self?.cancelledIndex(gen: gen) }
            catch { await self?.failedIndex(error, gen: gen) }
        }
    }
    private func importedExcel(_ imported: ExcelImportResult, store: CSVStore, gen: UUID) {
        guard generation == gen else { return }
        opened(store, gen: gen)
        excelNote = "Заголовок: строка \(imported.headerRow) листа."
        if imported.formulaCount > 0 { excelNote += " Формулы: сохранённые результаты, без пересчёта." }
        if imported.missingFormulaCount > 0 { excelNote += " Нет результата у \(imported.missingFormulaCount) формул." }
    }
    private func opened(_ store: CSVStore, gen: UUID) {
        guard generation == gen else { return }
        self.store = store; headers = store.headers; delimiter = store.format.delimiter; encoding = store.format.encoding; columns = []
    }
    private func indexed(_ count: Int64, fraction: Double, gen: UUID) {
        guard generation == gen else { return }
        total = count; progress = fraction; status = "Индексирование: \(count) записей. Поиск пока неполный."
        if !searching && (pageRows.isEmpty || exhausted) { search(reset: false, debounce: false) }
    }
    private func finishedIndex(gen: UUID) {
        guard generation == gen else { return }
        indexing = false; complete = true; progress = 1; status = "Индекс готов · \(total) записей" + (sheetName.map { " · " + $0 } ?? ""); search(reset: false, debounce: false)
    }
    private func cancelledIndex(gen: UUID) {
        guard generation == gen else { return }; indexing = false; status = store == nil ? "Импорт остановлен. Можно выбрать лист заново." : "Индексирование остановлено. Поиск неполный; экспорт недоступен."
    }
    private func failedIndex(_ e: Error, gen: UUID) {
        guard generation == gen else { return }; indexing = false; error = e.localizedDescription; status = "Индекс не завершён"
    }
    func cancelIndex() { indexToken.cancel() }
    func reloadFormat() { if workbook != nil { openSelectedSheet(); return }; if let source { open(source, format: CSVFormat(delimiter: delimiter, encoding: encoding)) } }
    func search(reset: Bool = true, debounce: Bool = true) {
        searchToken.cancel(); searchID = UUID()
        if countSpec != spec || countRevision != store?.editRevision {
            countToken.cancel(); countSpec = nil; found = nil
        }
        let id = searchID, gen = generation
        if reset { pendingTableMove = nil; starts = [0]; pageNumber = 1 }
        guard let store else { return }
        let spec = spec, start = starts.last ?? 0, token = Cancellation(), wrapped = wrapCells
        searchToken = token; searching = true
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if debounce { try await Task.sleep(nanoseconds: 250_000_000) }
                try token.check()
                let page = try store.page(spec: spec, after: start, wrappedPreview: wrapped, token: token)
                try token.check()
                await self?.searched(page, id: id, gen: gen)
            } catch is CancellationError {} catch { await self?.searchFailed(error, id: id) }
        }
    }
    private func searched(_ page: SearchPage, id: UUID, gen: UUID) {
        guard searchID == id && generation == gen else { return }
        pageRevision = UUID()
        pageRows = page.rows; cursor = page.cursor; exhausted = page.exhausted; searching = false
        if let pending = pendingTableMove {
            pendingTableMove = nil
            if let row = pending.direction > 0 ? pageRows.first : pageRows.last {
                select(row: row.id, column: pending.column, additive: false)
            }
        }
        if complete { countMatches() }
    }
    private func searchFailed(_ e: Error, id: UUID) { guard searchID == id else { return }; searching = false; pendingTableMove = nil; error = e.localizedDescription }
    private func countMatches() {
        guard let store else { return }
        if query.isEmpty { found = total; return }
        let token = Cancellation(), spec = spec
        guard countSpec != spec || countRevision != store.editRevision else { return }
        countSpec = spec; countRevision = store.editRevision
        countToken = token
        countTask = Task.detached(priority: .utility) { [weak self] in
            do {
                var count: Int64 = 0
                try store.visit(spec: spec, token: token) { _, _ in count += 1 }
                try token.check()
                await self?.counted(count, token: token)
            } catch { await self?.counted(nil, token: token) }
        }
    }
    private func counted(_ count: Int64?, token: Cancellation) {
        guard countToken === token, !token.isCancelled else { return }
        found = count
        if count == nil { countSpec = nil }
    }
    func cancelSearch() { countSpec = nil; searchToken.cancel(); countToken.cancel(); searchID = UUID(); searching = false; pendingTableMove = nil }
    func nextPage() { guard !exhausted && !searching else { return }; starts.append(cursor); pageNumber = starts.count; search(reset: false, debounce: false) }
    func previousPage() { guard starts.count > 1 else { return }; starts.removeLast(); pageNumber = starts.count; search(reset: false, debounce: false) }
    func moveTableSelection(direction: Int, column: Int?) {
        guard !searching, !pageRows.isEmpty, !headers.isEmpty else { return }
        let column = column.map { min(max(0, $0), headers.count - 1) }
        guard let index = pageRows.firstIndex(where: { $0.id == activeCell?.row }) else {
            let row = direction > 0 ? pageRows.first! : pageRows.last!
            select(row: row.id, column: column, additive: false)
            return
        }
        let target = index + direction
        if pageRows.indices.contains(target) {
            select(row: pageRows[target].id, column: column, additive: false)
        } else if direction > 0 && !exhausted {
            pendingTableMove = (direction, column); nextPage()
        } else if direction < 0 && pageNumber > 1 {
            pendingTableMove = (direction, column); previousPage()
        }
    }
    func select(row: Int64, column: Int?, additive: Bool) {
        if !additive { selectedRows = []; selectedCells = [] }
        if let column {
            let cell = CellID(row: row, column: column)
            if additive && selectedCells.contains(cell) { selectedCells.remove(cell) } else { selectedCells.insert(cell) }
            inspect(cell)
        } else {
            if additive && selectedRows.contains(row) { selectedRows.remove(row) } else { selectedRows.insert(row) }
            inspect(CellID(row: row, column: headers.firstIndex(of: "message") ?? 0))
        }
    }
    func inspect(_ cell: CellID) {
        guard let store, store.headers.indices.contains(cell.column) else { return }
        activeCell = cell; detail = nil; detailLoading = true; detailToken.cancel(); detailID = UUID()
        let id = detailID, token = Cancellation(); detailToken = token
        detailTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let values = try store.readRow(cell.row); try token.check()
                let data = try DetailData(values: values, headers: store.headers, column: cell.column, token: token)
                try token.check(); await self?.inspected(data, id: id)
            } catch is CancellationError {} catch { await self?.detailFailed(error, id: id) }
        }
    }
    private func inspected(_ data: DetailData, id: UUID) { guard detailID == id else { return }; detail = data; detailLoading = false }
    private func detailFailed(_ e: Error, id: UUID) { guard detailID == id else { return }; error = e.localizedDescription; detailLoading = false }
    func copyDetail(formatted: Bool = false) {
        guard let detail else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(formatted ? detail.pretty : detail.raw, forType: .string)
    }
    func beginExport() {
        var request = ExportRequest(); request.search = spec; request.rows = selectedRows; request.cells = selectedCells
        request.scope = !selectedCells.isEmpty ? .cells : (!selectedRows.isEmpty ? .rows : (query.isEmpty ? .all : .results))
        exportAnalysis = nil
        exportRequest = request; exportReport = nil; exportStatus = ""; showExport = true
    }
    func performExport(_ request: ExportRequest, destination: URL?) {
        guard let store, !exporting else { return }
        exportToken = Cancellation(); let token = exportToken
        let run = UUID(); exportRun = run
        let prepared = destination == nil ? nil : exportAnalysis
        if !request.rules.enabled { exportAnalysis = nil; exportReport = nil }
        if destination == nil { exportAnalysis = nil; exportReport = nil }
        exporting = true
        let stage = destination == nil ? "Анализ" : "Сохранение"
        exportStatus = stage + "…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let progress: (Int64) -> Void = { count in
                    Task { @MainActor [weak self] in
                        guard let self, self.exporting, self.exportRun == run else { return }
                        self.exportStatus = "\(stage): \(count) записей"
                    }
                }
                if destination == nil {
                    let analysis = try analyzeExport(store, request: request, token: token, progress: progress)
                    let report = try analysis.report(excluded: request.rules.excluded)
                    try token.check()
                    await self?.analysisFinished(analysis, report: report)
                } else {
                    if request.rules.enabled && prepared == nil { throw ScopeError("Сначала выполните анализ замен.") }
                    let report = try export(store, request: request, destination: destination, token: token, analysis: prepared, progress: progress)
                    await self?.exportFinished(report, saved: destination)
                }
            } catch is CancellationError { await self?.exportCancelled() }
            catch { await self?.exportFailed(error) }
        }
    }
    private func analysisFinished(_ analysis: MaskAnalysis, report: ExportReport) {
        exportAnalysis = analysis
        exportFinished(report, saved: nil)
    }
    func refreshExportReport(excluded: Set<String>, page: Int) {
        guard let analysis = exportAnalysis, !exporting else { return }
        exporting = true; exportStatus = "Обновление списка замен…"
        exportToken = Cancellation(); let token = exportToken
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let report = try analysis.report(excluded: excluded, offset: page * 80)
                try token.check()
                await self?.exportFinished(report, saved: nil)
            } catch is CancellationError { await self?.exportCancelled() }
            catch { await self?.exportFailed(error) }
        }
    }
    func exportExtension(_ request: ExportRequest) async throws -> String {
        guard request.singleValue else { return "csv" }
        if request.rules.enabled { return exportReport?.singleValueIsJSON == true ? "json" : "txt" }
        guard let store, let cell = request.cells.first else { throw ScopeError("Не выбрана ячейка.") }
        return try await Task.detached {
            try store.validate()
            let values = try store.readRow(cell.row)
            guard values.indices.contains(cell.column) else { throw ScopeError("Некорректная колонка.") }
            return (try? JSONSerialization.jsonObject(with: Data(values[cell.column].utf8), options: [.fragmentsAllowed])) == nil ? "txt" : "json"
        }.value
    }
    func endExport() { exportAnalysis = nil; exportReport = nil }
    private func exportFinished(_ report: ExportReport, saved: URL?) {
        exporting = false; exportReport = exportAnalysis == nil && saved != nil ? nil : report
        exportStatus = saved.map { "Сохранено: " + $0.lastPathComponent } ?? "Предпросмотр готов: \(report.records) записей, \(report.replacements) замен"
    }
    private func exportCancelled() { exporting = false; exportStatus = "Операция отменена" }
    private func exportFailed(_ e: Error) { exporting = false; exportReport = nil; exportAnalysis = nil; exportStatus = "Ошибка: " + e.localizedDescription }
    func cancelExport() { exportToken.cancel() }
    func clearCache() {
        guard let store, !exporting, editingCell == nil, confirmDiscardEdits() else { return }
        editedCells = []
        resetDocumentState()

        let tasks = [indexTask, searchTask, countTask, detailTask]
        self.store = nil; source = nil; workbook = nil; sheetName = nil; excelNote = ""
        indexing = false; complete = false; total = 0; progress = 0; searching = false
        Task {
            for task in tasks { await task?.value }
            do { try store.deleteCache(); status = "Кеш файла удалён" } catch { self.error = error.localizedDescription }
        }
    }
    private func checkSource() {
        guard let store else { return }
        do { try store.validate() } catch {
            resetDocumentState(); exportToken.cancel()

            complete = false; indexing = false; searching = false
            exportAnalysis = nil; exportReport = nil
            self.store = nil; status = "Исходный файл изменился — откройте заново"; self.error = error.localizedDescription
        }
    }
}

final class JSONItem: Identifiable, @unchecked Sendable {
    let id = UUID()
    let label: String
    let scalar: String?
    let children: [JSONItem]
    init(label: String, value: Any, token: Cancellation, depth: Int = 0) throws {
        try token.check(); self.label = label
        if depth > 128 { scalar = "Слишком глубокая ветка — используйте исходный текст"; children = []; return }
        if let dict = value as? [String: Any] {
            scalar = nil; children = try dict.keys.sorted().map { try JSONItem(label: $0, value: dict[$0]!, token: token, depth: depth + 1) }
        } else if let array = value as? [Any] {
            scalar = nil; children = try array.enumerated().map { try JSONItem(label: "[\($0.offset)]", value: $0.element, token: token, depth: depth + 1) }
        } else if let string = value as? String {
            let trim = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trim.first == "{" || trim.first == "["), let nested = try? JSONSerialization.jsonObject(with: Data(trim.utf8)) {
                scalar = nil; children = [try JSONItem(label: "JSON в строке", value: nested, token: token, depth: depth + 1)]
            } else { scalar = string; children = [] }
        } else { scalar = value is NSNull ? "null" : String(describing: value); children = [] }
    }
}
struct DetailData: @unchecked Sendable {
    let raw: String
    let pretty: String
    let rawPages: [String]
    let prettyPages: [String]
    let id = UUID()
    let label: String
    let jsonValue: Any?
    let bracketStates: [JSONBracketState]
    let prefix: String
    let suffix: String
    init(values: [String], headers: [String], column: Int, token: Cancellation) throws {
        guard values.indices.contains(column), headers.indices.contains(column) else { throw ScopeError("Некорректная колонка.") }
        label = headers[column]
        raw = values[column]
        if let envelope = try extractJSON(raw, fragments: true, token: token) {
            prefix = envelope.prefix; suffix = envelope.suffix
            let data = try JSONSerialization.data(withJSONObject: envelope.value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
            let json = String(decoding: data, as: UTF8.self)
            pretty = (prefix.isEmpty ? "" : prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n") + json + (suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n" + suffix)
            jsonValue = envelope.value
        } else { jsonValue = nil; prefix = ""; suffix = ""; pretty = raw }
        rawPages = Self.pages(raw)
        prettyPages = pretty == raw ? rawPages : Self.pages(pretty)
        var state = JSONBracketState()
        var states: [JSONBracketState] = []
        if jsonValue != nil && prettyPages.count > 1 {
            for page in prettyPages.dropLast() {
                try token.check()
                for character in page.utf16 { _ = state.consume(character) }
                states.append(state)
            }
        }
        bracketStates = states
    }
}

extension DetailData {
    private static func pages(_ text: String) -> [String] {
        var result: [String] = [], start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start, offsetBy: 32000, limitedBy: text.endIndex) ?? text.endIndex
            if end != text.endIndex, let newline = text[start..<end].lastIndex(of: "\n") {
                end = text.index(after: newline)
            }
            result.append(String(text[start..<end])); start = end
        }
        return result.isEmpty ? [""] : result
    }
}

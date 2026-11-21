import SwiftUI
import AppKit
import JSONicCore

@main struct JSONicApp: App {
    @NSApplicationDelegateAdaptor(EditCloseGuard.self) private var closeGuard
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("JSONic") {
            ContentView(model: model).frame(minWidth: 1000, minHeight: 680)
                .preferredColorScheme(.dark)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); closeGuard.model = model; NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.delegate = closeGuard } }
                .onOpenURL { model.open($0) }
        }
        .commands {
            CommandMenu("Поиск") {
                Button("Найти в выбранной ячейке") { NotificationCenter.default.post(name: .cellFind, object: nil) }.keyboardShortcut("f").disabled(model.detail == nil || model.showExport)
                Button("Следующее совпадение") { NotificationCenter.default.post(name: .cellFindNext, object: nil) }.keyboardShortcut("g").disabled(model.detail == nil || model.showExport)
                Button("Предыдущее совпадение") { NotificationCenter.default.post(name: .cellFindPrevious, object: nil) }.keyboardShortcut("g", modifiers: [.command, .shift]).disabled(model.detail == nil || model.showExport)
            }
            CommandGroup(replacing: .newItem) { Button("Открыть файл…") { model.pickFile() }.keyboardShortcut("o").disabled(model.exporting) }
        }
    }
}
struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var expanded = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.tint)
                Text(model.source?.lastPathComponent ?? "JSONic").font(.headline).lineLimit(1)
                if let name = model.sheetName { Text("· " + name).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                if model.workbook != nil { Button("Листы…") { model.showSheetPicker = true }.disabled(model.indexing || model.exporting) }
                Button("Открыть файл…", action: model.pickFile).disabled(model.exporting)
                Button("Экспорт…", action: model.beginExport).buttonStyle(.borderedProminent).disabled(!model.complete || model.exporting)
            }.padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            HSplitView {
                if !expanded { CSVListPane(model: model).frame(minWidth: 350, idealWidth: 470) }
                DetailView(model: model, expanded: $expanded).frame(minWidth: 430, idealWidth: 750)
            }
            Divider()
            HStack {
                if model.indexing { ProgressView(value: model.progress).frame(width: 100); Button("Отмена", action: model.cancelIndex) }
                Text(model.status).lineLimit(1).help(model.excelNote.isEmpty ? model.status : model.excelNote)
                Spacer()
                if !model.editedCells.isEmpty { Text("Правок: \(model.editedCells.count) · сохранение через экспорт") }
                Text("Строк: \(model.selectedRows.count) · ячеек: \(model.selectedCells.count)")
                Button("Снять выделение") { model.selectedRows = []; model.selectedCells = [] }.disabled(model.selectedRows.isEmpty && model.selectedCells.isEmpty)
            }.font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
        }
        .sheet(isPresented: Binding(get: { model.editingCell != nil }, set: { if !$0 && !model.savingEdit { model.editingCell = nil } })) { CellEditor(model: model).interactiveDismissDisabled() }
        .sheet(isPresented: $model.showExport) { ExportView(model: model) }
        .sheet(isPresented: $model.showSheetPicker) { ExcelSheetPicker(model: model) }
        .alert("JSONic", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
struct CSVListPane: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Поиск по таблице", text: $model.query).textFieldStyle(.roundedBorder)
                    .onChange(of: model.query) { _ in model.search() }
                Menu {
                    Button("Все колонки") { model.columns = []; model.search() }
                    ForEach(Array(model.headers.enumerated()), id: \.offset) { index, title in
                        Toggle(title, isOn: Binding(get: { model.columns.contains(index) }, set: { selected in
                            if selected { model.columns.insert(index) } else { model.columns.remove(index) }; model.search()
                        }))
                    }
                    Divider()
                    Toggle("Учитывать регистр", isOn: $model.caseSensitive).onChange(of: model.caseSensitive) { _ in model.search() }
                } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.menuStyle(.borderlessButton).fixedSize().help("Колонки и регистр поиска")
                Menu {
                    if model.workbook == nil {
                    Picker("Разделитель", selection: $model.delimiter) {
                        Text("Запятая").tag(UInt8(44)); Text("Точка с запятой").tag(UInt8(59)); Text("Табуляция").tag(UInt8(9))
                    }
                    Picker("Кодировка", selection: $model.encoding) { ForEach(CSVEncoding.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Button("Перечитать с выбранными настройками", action: model.reloadFormat).disabled(model.source == nil || model.exporting)
                    } else {
                        Button("Выбрать лист…") { model.showSheetPicker = true }.disabled(model.indexing || model.exporting)
                        Button("Перечитать лист", action: model.reloadFormat).disabled(model.indexing || model.exporting)
                        Text(model.excelNote)
                    }
                    Divider()
                    Button("Удалить кеш файла", action: model.clearCache).disabled(model.store == nil || model.exporting)
                } label: { Image(systemName: "slider.horizontal.3") }.menuStyle(.borderlessButton).fixedSize().help("Настройки таблицы")
                Toggle(isOn: $model.wrapCells) { WrapLinesIcon().frame(width: 22, height: 18) }
                    .accessibilityLabel("Перенос строк")
                    .toggleStyle(.button).fixedSize().help("Перенос строк в ячейках (до 8 строк; полный текст — в панели просмотра)")
                    .onChange(of: model.wrapCells) { _ in model.search(reset: false, debounce: false) }
                if model.searching { ProgressView().controlSize(.small); Button(action: model.cancelSearch) { Image(systemName: "xmark") } }
            }.padding(8)
            Divider()
            if model.headers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tablecells").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Откройте CSV или Excel")
                    Text("Клик — ячейка, номер — строка. Cmd-клик добавляет к выделению.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { RecordsTable(model: model) }
            Divider()
            HStack {
                Button(action: model.previousPage) { Image(systemName: "chevron.left") }.disabled(model.pageNumber <= 1 || model.searching)
                Text("Страница \(model.pageNumber)")
                Button(action: model.nextPage) { Image(systemName: "chevron.right") }.disabled(model.exhausted || model.searching)
                Spacer()
                Text(model.found.map { "Найдено: \($0)" } ?? "На странице: \(model.pageRows.count)")
            }.font(.caption).padding(8)
        }
    }
}
struct DetailView: View {
    @ObservedObject var model: AppModel
    @Binding var expanded: Bool
    @State private var treeRoot: JSONItem?
    @State private var mode = "JSON"
    @State private var findRequest: UUID?
    @AppStorage("viewerFontSize") private var fontSize = 16.0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let cell = model.activeCell {
                    Text("№ \(cell.row)").font(.caption).foregroundStyle(.secondary)
                    Picker("Колонка", selection: Binding(get: { cell.column }, set: { model.inspect(CellID(row: cell.row, column: $0)) })) {
                        ForEach(Array(model.headers.enumerated()), id: \.offset) { Text($0.element).tag($0.offset) }
                    }.labelsHidden().frame(maxWidth: 140)
                } else { Text("Просмотр ячейки").font(.headline) }
                Picker("Вид", selection: $mode) {
                    Text("JSON").tag("JSON"); Text("Дерево").tag("Дерево"); Text("Исходник").tag("Исходник")
                }.labelsHidden().frame(width: 105)
                Spacer(minLength: 0)
                Button { if mode == "Дерево" { mode = "JSON" }; findRequest = UUID() } label: { Image(systemName: "magnifyingglass") }.help("Найти в ячейке (⌘F)").disabled(model.detail == nil)
                Menu {
                    Text("Размер текста: \(Int(fontSize))")
                    Button("Увеличить шрифт") { fontSize = min(28, fontSize + 1) }
                    Button("Уменьшить шрифт") { fontSize = max(12, fontSize - 1) }
                    Divider()
                    Button("Выбрать эту ячейку для экспорта") { if let cell = model.activeCell { model.selectedCells.insert(cell) } }.disabled(model.activeCell == nil)
                } label: { Text("Aa") }.menuStyle(.borderlessButton).fixedSize().help("Шрифт и действия с ячейкой")
                Button { model.copyDetail(formatted: mode == "JSON") } label: { Image(systemName: "doc.on.doc") }.help("Копировать значение").disabled(model.detail == nil)
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.help(expanded ? "Вернуть таблицу" : "Развернуть JSON на всю ширину")
            }.controlSize(.small).padding(8)
            Divider()
            if model.detailLoading { ProgressView("Чтение и разбор…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let detail = model.detail {
                if mode == "Дерево", detail.jsonValue != nil {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let root = treeRoot {
                            if !detail.prefix.isEmpty { ChunkedText(value: detail.prefix).foregroundStyle(.secondary) }
                            JSONBranch(item: root, initiallyExpanded: true, fontSize: fontSize).id(root.id)
                            if !detail.suffix.isEmpty { ChunkedText(value: detail.suffix).foregroundStyle(.secondary) }
                        } else { ProgressView() }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(model.activeCell)
                .task(id: detail.id) {
                    treeRoot = nil
                    let token = Cancellation()
                    let root = await withTaskCancellationHandler {
                        await Task.detached {
                            try? detail.jsonValue.map { try JSONItem(label: detail.label, value: $0, token: token) }
                        }.value
                    } onCancel: { token.cancel() }
                    if !Task.isCancelled { treeRoot = root }
                }
                .onDisappear { treeRoot = nil }
                } else {
                    CodeViewer(pages: mode == "JSON" ? detail.prettyPages : detail.rawPages, bracketStates: detail.bracketStates, fontSize: fontSize, highlight: mode == "JSON" && detail.jsonValue != nil, findRequest: findRequest)
                        .id("\(model.activeCell?.row ?? 0)-\(model.activeCell?.column ?? 0)-\(mode)")
                }
                if detail.jsonValue == nil { Text("Текст или некорректный JSON").font(.caption).foregroundStyle(.secondary) }
            } else { Text("Выберите ячейку для просмотра").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cellFind)) { _ in
            if mode == "Дерево" { mode = "JSON" }
            findRequest = UUID()
        }
    }
}
struct ChunkedText: View {
    let value: String
    var fontSize: Double = 16
    @State private var page = 0
    private let chunkSize = 8000
    var body: some View {
        let start = value.index(value.startIndex, offsetBy: page * chunkSize, limitedBy: value.endIndex) ?? value.endIndex
        let end = value.index(start, offsetBy: chunkSize, limitedBy: value.endIndex) ?? value.endIndex
        VStack(alignment: .leading, spacing: 10) {
            Text(String(value[start..<end]))
                .font(.system(size: fontSize, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            if page > 0 || end < value.endIndex {
                HStack {
                    Button("Назад") { page = max(0, page - 1) }.disabled(page == 0)
                    Text("Часть \(page + 1)").font(.caption)
                    Button("Далее") { page += 1 }.disabled(end == value.endIndex)
                }
            }
        }
    }
}
struct JSONBranch: View {
    let item: JSONItem
    let fontSize: Double
    @State private var expanded = false
    @State private var count = 100
    init(item: JSONItem, initiallyExpanded: Bool = false, fontSize: Double = 16) {
        self.item = item; self.fontSize = fontSize
        _expanded = State(initialValue: initiallyExpanded)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let scalar = item.scalar {
                Text(item.label + ":").font(.system(size: fontSize, design: .monospaced)).foregroundStyle(.secondary)
                ChunkedText(value: scalar, fontSize: fontSize)
            } else {
                Button { expanded.toggle() } label: {
                    HStack {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        Text(item.label).fontWeight(.medium)
                        Text("\(item.children.count) элементов").foregroundStyle(.secondary)
                    }.font(.system(size: fontSize, design: .monospaced))
                }.buttonStyle(.plain)
                if expanded {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(item.children.prefix(count))) { child in JSONBranch(item: child, fontSize: fontSize) }
                        if count < item.children.count { Button("Ещё 100 элементов") { count += 100 } }
                    }.padding(.leading, 18)
                }
            }
        }
    }
}


struct ExcelSheetPicker: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Выберите лист Excel").font(.title2)
            Text(model.source?.lastPathComponent ?? "").foregroundStyle(.secondary).lineLimit(2)
            Picker("Лист", selection: $model.selectedSheet) {
                ForEach(model.workbook?.sheets ?? []) { sheet in
                    Text(sheet.name + (sheet.hidden ? " (скрытый)" : "")).tag(sheet.id)
                }
            }
            Text("Первая непустая строка станет заголовком. Формулы читаются по сохранённым результатам, без пересчёта. Экспорт — CSV или отдельная ячейка JSON/TXT.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Отмена") { model.showSheetPicker = false }
                Spacer()
                Button("Открыть лист", action: model.openSelectedSheet).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480)
    }
}

struct CellEditor: View {
    @ObservedObject var model: AppModel
    @State private var confirmCancel = false
    @State private var invalidJSON = false
    @State private var parseError = ""
    private func cancel() {
        if model.editorText == model.editorOriginal { model.editingCell = nil }
        else { confirmCancel = true }
    }
    private func apply() {
        let text = model.editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") || text.hasPrefix("[") {
            do { _ = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) }
            catch { parseError = error.localizedDescription; invalidJSON = true; return }
        }
        model.applyEdit()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Редактирование · строка \(model.editingCell?.row ?? 0)").font(.headline)
            Text("Исходный файл не изменится. Применённые правки сохраняются через экспорт копии.").foregroundStyle(.secondary)
            TextEditor(text: $model.editorText).font(.system(size: 16, design: .monospaced)).disabled(model.savingEdit)
            HStack {
                Button("Форматировать JSON") {
                    do {
                        let value = try JSONSerialization.jsonObject(with: Data(model.editorText.utf8), options: [.fragmentsAllowed])
                        model.editorText = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .fragmentsAllowed, .sortedKeys]), as: UTF8.self)
                    } catch { parseError = error.localizedDescription; invalidJSON = true }
                }.disabled(model.savingEdit)
                Spacer()
                if model.savingEdit { ProgressView().controlSize(.small) }
                Button("Отмена", action: cancel).keyboardShortcut(.cancelAction).disabled(model.savingEdit)
                Button("Применить", action: apply).keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent).disabled(model.savingEdit)
            }
        }.padding(16).frame(minWidth: 700, minHeight: 480)
        .alert("Отбросить изменения ячейки?", isPresented: $confirmCancel) {
            Button("Продолжить редактирование", role: .cancel) {}
            Button("Отбросить", role: .destructive) { model.editingCell = nil }
        }
        .alert("Не удалось разобрать JSON", isPresented: $invalidJSON) {
            Button("Вернуться к редактированию", role: .cancel) {}
            Button("Применить как текст") { model.applyEdit() }
        } message: { Text(parseError) }
    }
}

@MainActor final class EditCloseGuard: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set the running Dock icon explicitly as well as declaring it in Info.plist.
        // Launch Services may retain the placeholder from an earlier local build.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: url), icon.isValid {
            NSApp.applicationIconImage = icon
        }
    }
    weak var model: AppModel?
    private func mayClose() -> Bool {
        guard let model else { return true }
        if model.exporting || model.savingEdit || model.editingCell != nil { NSSound.beep(); return false }
        return model.confirmDiscardEdits()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { mayClose() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { mayClose() ? .terminateNow : .terminateCancel }
}

/// Drawn locally so this control does not depend on SF Symbols availability.
private struct WrapLinesIcon: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 1, y: 2))
            path.addLine(to: CGPoint(x: 21, y: 2))
            path.move(to: CGPoint(x: 1, y: 8))
            path.addLine(to: CGPoint(x: 16, y: 8))
            path.addCurve(to: CGPoint(x: 16, y: 15), control1: CGPoint(x: 23, y: 8), control2: CGPoint(x: 23, y: 15))
            path.addLine(to: CGPoint(x: 11, y: 15))
            path.move(to: CGPoint(x: 14, y: 12))
            path.addLine(to: CGPoint(x: 11, y: 15))
            path.addLine(to: CGPoint(x: 14, y: 18))
            path.move(to: CGPoint(x: 1, y: 15))
            path.addLine(to: CGPoint(x: 6, y: 15))
        }.stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        .padding(.vertical, 1)
    }
}

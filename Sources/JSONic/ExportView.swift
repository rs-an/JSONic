import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JSONicCore

struct ExportView: View {
    @ObservedObject var model: AppModel
    @State private var scope: ExportScope = .all
    @State private var mask = true
    @State private var phones = true
    @State private var automaticNames = true
    @State private var single = false
    @State private var protectFormulas = true
    @State private var additionalTypes = MaskKind.defaultAdditional
    @State private var phoneColumns = ""
    @State private var nameColumns = ""
    @State private var phoneKeys = ""
    @State private var nameKeys = ""
    @State private var names = ""
    @State private var excluded: Set<String> = []
    @State private var candidatePage = 0
    @State private var showSettings = false
    @State private var previewSignature: String?
    private var signature: String { [scope.rawValue, String(mask), String(phones), String(automaticNames), phoneColumns, nameColumns, phoneKeys, nameKeys, names, additionalTypes.map(\.rawValue).sorted().joined(separator: ",")].joined(separator: "\n") }
    private var currentPreview: Bool { previewSignature == signature && model.exportReport != nil }
    private var canPreview: Bool {
        !model.exporting && model.store != nil && model.complete && (scope != .cells || !(model.exportRequest?.cells.isEmpty ?? true)) && (scope != .rows || !(model.exportRequest?.rows.isEmpty ?? true))
    }
    private func entries(_ value: String) -> [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty } }
    private func request() -> ExportRequest {
        var value = model.exportRequest ?? ExportRequest()
        value.scope = scope; value.singleValue = single && scope == .cells && value.cells.count == 1
        value.protectSpreadsheetFormulas = protectFormulas
        value.rules = MaskRules()
        value.rules.enabled = mask; value.rules.phonesInText = phones; value.rules.automaticNames = automaticNames; value.rules.excluded = excluded; value.rules.additionalTypes = additionalTypes
        for key in entries(phoneColumns) { value.rules.columns[key] = .phone }
        for key in entries(nameColumns) { value.rules.columns[key] = .person }
        for key in entries(phoneKeys) { value.rules.keys[key] = .phone }
        for key in entries(nameKeys) { value.rules.keys[key] = .person }
        value.rules.names = names.split(separator: "\n").map { line in line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }.filter { !$0.isEmpty }
        return value
    }
    private func preview() {
        candidatePage = 0
        previewSignature = signature
        model.performExport(request(), destination: nil)
    }
    private func save() {
        if mask && !currentPreview { preview(); return }
        let request = request()
        Task { @MainActor in
            do {
                let ext = try await model.exportExtension(request)
                let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
                panel.nameFieldStringValue = (model.source?.deletingPathExtension().lastPathComponent ?? "export") + (mask ? "-masked." : "-selected.") + ext
                if panel.runModal() == .OK, let url = panel.url { candidatePage = 0; model.performExport(request, destination: url) }
            } catch { model.exportStatus = "Ошибка: " + error.localizedDescription }
        }
    }
    private var blockedReason: String? {
        if model.exporting { return "Дождитесь завершения операции или нажмите «Отмена»." }
        if model.store == nil { return "Откройте исходный файл заново." }
        if !model.complete { return "Дождитесь завершения индексирования." }
        if !canPreview { return "В выбранной области нет строк или ячеек." }
        return nil
    }
    private var singleCell: Bool { scope == .cells && model.exportRequest?.cells.count == 1 }
    private var footerStatus: String? {
        let status = model.exportStatus
        guard !status.isEmpty else { return nil }
        if model.exporting || status.hasPrefix("Ошибка:") || status.hasPrefix("Сохранено:") || status == "Операция отменена" { return status }
        return nil
    }
    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Настройки экспорта").font(.headline)
                    Spacer()
                    Button("Готово") { showSettings = false }
                }
                if !(single && singleCell) {
                    Toggle("Защита CSV от формул", isOn: $protectFormulas)
                        .help("Добавляет апостроф перед значениями, похожими на формулы. Отключите для точного сохранения исходных значений.")
                }
                if mask {
                    Text("Что маскировать").font(.subheadline).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2), alignment: .leading, spacing: 12) {
                        Toggle("Телефоны", isOn: $phones)
                        Toggle("Имена и ФИО", isOn: $automaticNames)
                        ForEach(MaskKind.additional, id: \.self) { kind in
                            Toggle(kind.title, isOn: Binding(get: { additionalTypes.contains(kind) }, set: { enabled in
                                if enabled { additionalTypes.insert(kind) } else { additionalTypes.remove(kind) }
                            }))
                        }
                    }
                    Divider()
                    DisclosureGroup("Свои правила") {
                        VStack(alignment: .leading, spacing: 10) {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                GridRow { Text("Колонки: телефоны"); TextField("Через запятую", text: $phoneColumns) }
                                GridRow { Text("Колонки: имена"); TextField("Через запятую", text: $nameColumns) }
                                GridRow { Text("Ключи JSON: телефоны"); TextField("Через запятую", text: $phoneKeys) }
                                GridRow { Text("Ключи JSON: имена"); TextField("Через запятую", text: $nameKeys) }
                            }.textFieldStyle(.roundedBorder)
                            Text("Имена — по одному на строку. Варианты: Анна | Анне").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $names).font(.system(.body, design: .monospaced))
                                .frame(height: 72).border(Color.secondary.opacity(0.25))
                        }.padding(.top, 10)
                    }
                }
            }.padding(20)
        }.frame(width: 480).frame(maxHeight: 540)
    }
    private func replacementRow(_ item: MaskExample) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("Маскировать " + item.original, isOn: Binding(get: { !excluded.contains(item.identity) }, set: { enabled in
                if enabled { excluded.remove(item.identity) } else { excluded.insert(item.identity) }
                model.refreshExportReport(excluded: excluded, page: candidatePage)
            })).labelsHidden().disabled(model.exporting)
                .help("Отключите, чтобы сохранить это значение во всех его повторах.")
            Text(item.original).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).help(item.original)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            Text(excluded.contains(item.identity) ? "Без замены" : item.replacement)
                .foregroundStyle(excluded.contains(item.identity) ? Color.secondary : Color.primary)
                .frame(width: 145, alignment: .leading)
            Text(item.rule).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).frame(width: 160, alignment: .leading).help(item.rule)
        }.font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            .padding(.horizontal, 12).padding(.vertical, 9)
    }
    private var replacements: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Замены").font(.headline)
                if let report = model.exportReport {
                    Text(String(report.replacements)).font(.headline).foregroundStyle(.secondary)
                    Spacer()
                    Text("Записей: \(report.records)").foregroundStyle(.secondary)
                    if report.skipped > 0 { Text("Без замены: \(report.skipped)").foregroundStyle(.secondary) }
                }
            }
            if let report = model.exportReport {
                if !currentPreview {
                    Label("Настройки изменены. Обновите список замен.", systemImage: "arrow.clockwise")
                        .font(.callout).foregroundStyle(.orange)
                }
                if report.malformedJSON > 0 {
                    DisclosureGroup("Ошибки JSON: \(report.malformedJSON)") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Для этих значений доступны только текстовые правила.")
                                ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                                    Text("Строка \(issue.row), \(issue.column): \(issue.reason)")
                                }
                                if report.malformedJSON > report.issues.count { Text("Показаны первые 80 ошибок.") }
                            }
                        }.frame(maxHeight: 100)
                    }.font(.caption).foregroundStyle(.orange)
                }
                if report.exampleCount == 0 {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.title2).foregroundStyle(.secondary)
                        Text("Совпадений не найдено")
                        Text("Автоматическая проверка может пропустить чувствительные данные.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            Text("Исходное значение").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 28)
                            Text("Замена").frame(width: 145, alignment: .leading)
                            Text("Правило").frame(width: 160, alignment: .leading)
                        }.font(.caption).foregroundStyle(.secondary).padding(12)
                        Divider()
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(report.examples) { item in
                                    replacementRow(item)
                                    Divider().padding(.leading, 12)
                                }
                            }
                        }
                    }.background(Color.primary.opacity(0.025))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18)))
                    if report.exampleCount > 80 {
                        HStack {
                            Button("Назад") { candidatePage -= 1; model.refreshExportReport(excluded: excluded, page: candidatePage) }
                                .disabled(model.exporting || candidatePage == 0)
                            Text("\(candidatePage + 1) / \((report.exampleCount + 79) / 80)").font(.caption).monospacedDigit()
                            Button("Далее") { candidatePage += 1; model.refreshExportReport(excluded: excluded, page: candidatePage) }
                                .disabled(model.exporting || (candidatePage + 1) * 80 >= report.exampleCount)
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    if model.exporting { ProgressView() }
                    else { Text("Обновите список замен").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Экспорт").font(.title2.weight(.semibold))
                Spacer()
                Button("Закрыть") { model.showExport = false }.disabled(model.exporting)
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Данные").font(.callout).foregroundStyle(.secondary)
                        Picker("Данные", selection: $scope) {
                            ForEach(ExportScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden().frame(width: 280, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Формат").font(.callout).foregroundStyle(.secondary)
                        if singleCell {
                            Picker("Формат", selection: $single) {
                                Text("CSV").tag(false)
                                Text("JSON / TXT").tag(true)
                            }.labelsHidden().frame(width: 180, alignment: .leading)
                        } else {
                            Text("CSV").frame(height: 22, alignment: .leading)
                        }
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Toggle("Маскирование данных", isOn: $mask).labelsHidden().toggleStyle(.switch).fixedSize()
                    Text("Маскирование данных")
                    Spacer()
                    Button { showSettings.toggle() } label: { Label("Настройки", systemImage: "slider.horizontal.3") }
                        .popover(isPresented: $showSettings, arrowEdge: .bottom) { settings }
                }
                if model.workbook != nil {
                    Text("Текущий лист экспортируется без оформления и формул Excel.").font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(model.exporting)
            Divider()
            if mask { replacements }
            else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.on.doc").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Сохранение без маскирования").font(.headline)
                    Text("Выбранные данные будут сохранены в отдельный файл.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            if let status = footerStatus { Text(status).font(.caption).textSelection(.enabled) }
            if !model.exporting, let reason = blockedReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if model.exporting {
                    ProgressView().controlSize(.small)
                    Button("Отменить", action: model.cancelExport)
                } else if mask {
                    Button("Обновить замены", action: preview).disabled(!canPreview)
                }
                Spacer()
                Button(mask && !currentPreview ? "Проверить замены" : "Сохранить…", action: save)
                    .buttonStyle(.borderedProminent).disabled(!canPreview)
            }
        }.padding(24).frame(width: 800, height: 660)
        .onAppear {
            scope = model.exportRequest?.scope ?? .all
            if canPreview { preview() }
        }
        .onDisappear { model.endExport() }
        .interactiveDismissDisabled(model.exporting)
    }
}

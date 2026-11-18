import SwiftUI
import AppKit
import JSONicCore

final class ClickTable: NSTableView {
    var onMove: ((Int, Int) -> Void)?
    var navigationColumn = 1
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if modifiers.isEmpty && (event.keyCode == 125 || event.keyCode == 126) {
            onMove?(event.keyCode == 125 ? 1 : -1, navigationColumn)
        } else { super.keyDown(with: event) }
    }
    // Text fields and AppKit key bindings can route arrows as responder commands.
    override func moveUp(_ sender: Any?) { onMove?(-1, navigationColumn) }
    override func moveDown(_ sender: Any?) { onMove?(1, navigationColumn) }
    var onEdit: ((Int, Int) -> Void)?
    var onClick: ((Int, Int, Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point), column = self.column(at: point)
        window?.makeFirstResponder(self)
        if event.clickCount == 2 && row >= 0 && column > 0 { onEdit?(row, column); return }
        if row >= 0 && column >= 0 { navigationColumn = column; onClick?(row, column, event.modifierFlags.contains(.command)) }
    }
}
private final class PreviewCell: NSView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
struct RecordsTable: NSViewRepresentable {
    @ObservedObject var model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let table = ClickTable(); table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.selectionHighlightStyle = .none
        table.rowHeight = 32; table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.onClick = { [weak model] row, col, additive in
            guard let model, model.pageRows.indices.contains(row) else { return }
            model.select(row: model.pageRows[row].id, column: col == 0 ? nil : col - 1, additive: additive)
        }
        table.onEdit = { [weak model] row, column in
            guard let model, model.pageRows.indices.contains(row) else { return }
            model.beginEditing(CellID(row: model.pageRows[row].id, column: column - 1))
        }
        table.onMove = { [weak model] direction, column in
            model?.moveTableSelection(direction: direction, column: column == 0 ? nil : column - 1)
        }
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? ClickTable else { return }
        context.coordinator.model = model
        let headers = ["№"] + model.headers
        if context.coordinator.headers != headers {
            for col in table.tableColumns { table.removeTableColumn(col) }
            for (i, title) in headers.enumerated() {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(i)))
                col.title = title; col.width = i == 0 ? 65 : (title == "message" ? 420 : 190); col.minWidth = 60
                table.addTableColumn(col)
            }
            table.navigationColumn = (model.headers.firstIndex(of: "message") ?? 0) + 1
            context.coordinator.headers = headers
        }
        let first = model.pageRows.first?.id
        let resetScroll = context.coordinator.first != first
        context.coordinator.first = first
        context.coordinator.updatingSelection = true
        let layoutChanged = context.coordinator.pageRevision != model.pageRevision || context.coordinator.wrapped != model.wrapCells
        context.coordinator.pageRevision = model.pageRevision; context.coordinator.wrapped = model.wrapCells
        if layoutChanged { context.coordinator.heights = [:] }
        table.reloadData()
        if layoutChanged { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<model.pageRows.count)) }
        if let index = model.pageRows.firstIndex(where: { $0.id == model.activeCell?.row }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        context.coordinator.updatingSelection = false
        if resetScroll {
            // Reload and row sizing must finish before revealing the new page's first row.
            scroll.layoutSubtreeIfNeeded()
            table.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
            if !model.pageRows.isEmpty { table.scrollRowToVisible(0) }
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if context.coordinator.activeRow != model.activeCell?.row {
            context.coordinator.activeRow = model.activeCell?.row
            if table.window?.firstResponder === table,
               let index = model.pageRows.firstIndex(where: { $0.id == model.activeCell?.row }) {
                table.scrollRowToVisible(index)
            }
        }
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: AppModel
        var headers: [String] = []
        var first: Int64?
        var activeRow: Int64?
        var updatingSelection = false
        var pageRevision: UUID?
        var wrapped = false
        var heights: [Int: CGFloat] = [:]
        func tableViewColumnDidResize(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            heights = [:]
            updatingSelection = true
            table.reloadData()
            updatingSelection = false
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<model.pageRows.count))
        }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard model.wrapCells, model.pageRows.indices.contains(row) else { return 32 }
            if let height = heights[row] { return height }
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            let maxHeight = ceil(NSLayoutManager().defaultLineHeight(for: font) * 8)
            var height: CGFloat = 20
            for (index, value) in model.pageRows[row].values.enumerated() {
                guard tableView.tableColumns.indices.contains(index + 1) else { continue }
                let bounds = (value as NSString).boundingRect(with: NSSize(width: max(10, tableView.tableColumns[index + 1].width - 12), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph])
                height = max(height, min(maxHeight, ceil(bounds.height)))
                if height >= maxHeight { break }
            }
            let result = max(32, height + 14); heights[row] = result; return result
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updatingSelection, let table = notification.object as? ClickTable,
                  model.pageRows.indices.contains(table.selectedRow) else { return }
            let row = model.pageRows[table.selectedRow].id
            guard row != model.activeCell?.row else { return }
            model.select(row: row, column: table.navigationColumn == 0 ? nil : table.navigationColumn - 1, additive: false)
        }
        init(_ model: AppModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { model.pageRows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, let index = Int(column.identifier.rawValue), model.pageRows.indices.contains(row) else { return nil }
            let item = model.pageRows[row]
            let id = NSUserInterfaceItemIdentifier("cell")
            let container = (tableView.makeView(withIdentifier: id, owner: nil) as? PreviewCell) ?? PreviewCell(frame: .zero)
            container.identifier = id
            let field = container.label
            field.lineBreakMode = model.wrapCells && index > 0 ? .byWordWrapping : .byTruncatingTail
            field.maximumNumberOfLines = model.wrapCells && index > 0 ? 8 : 1
            field.cell?.wraps = model.wrapCells && index > 0
            field.cell?.usesSingleLineMode = !model.wrapCells || index == 0
            field.cell?.truncatesLastVisibleLine = true
            field.preferredMaxLayoutWidth = max(10, column.width - 12)
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.stringValue = index == 0 ? String(item.id) : (item.values.indices.contains(index - 1) ? item.values[index - 1] : "")
            let selected = model.selectedRows.contains(item.id) || (index > 0 && model.selectedCells.contains(CellID(row: item.id, column: index - 1)))
            field.drawsBackground = selected; field.backgroundColor = selected ? NSColor.selectedContentBackgroundColor : .clear
            field.textColor = selected ? .white : .labelColor
            if index > 0 && model.editedCells.contains(CellID(row: item.id, column: index - 1)) { field.stringValue = "✎ " + field.stringValue }
            field.toolTip = index == 0 ? "Выбрать строку; Cmd-клик — добавить" : "Двойной клик — редактировать; Cmd-клик — добавить"
            return container
        }
    }
}

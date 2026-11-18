import SwiftUI
import AppKit

extension Notification.Name {
    static let cellFind = Notification.Name("JSONic.cellFind")
    static let cellFindNext = Notification.Name("JSONic.cellFindNext")
    static let cellFindPrevious = Notification.Name("JSONic.cellFindPrevious")
}

struct CodeViewer: View {
    let pages: [String]
    let fontSize: Double
    let highlight: Bool
    let findRequest: UUID?
    @State private var page = 0
    @State private var showFind = false
    @State private var query = ""
    @State private var matches: [NSRange] = []
    @State private var selected = 0
    @State private var searching = false
    @State private var reveal = UUID()
    @FocusState private var findFocused: Bool
    private var offsets: [Int] {
        var total = 0
        return pages.map { text in defer { total += (text as NSString).length }; return total }
    }
    private struct SearchInput: Equatable { let query: String; let pages: [String] }
    private func openFind() { showFind = true; findFocused = true }
    private func move(_ delta: Int) {
        guard !matches.isEmpty, !searching else { openFind(); return }
        selected = (selected + delta + matches.count) % matches.count
        revealSelected()
    }
    private func revealSelected() {
        guard matches.indices.contains(selected) else { return }
        let target = matches[selected].location
        page = offsets.lastIndex(where: { $0 <= target }) ?? 0
        reveal = UUID()
    }
    var body: some View {
        let visiblePage = min(page, pages.count - 1)
        let offset = offsets[visiblePage]
        let visible = NSRange(location: offset, length: (pages[visiblePage] as NSString).length)
        let localMatches = matches.compactMap { match -> NSRange? in
            let intersection = NSIntersectionRange(match, visible)
            return intersection.length > 0 ? NSRange(location: intersection.location - offset, length: intersection.length) : nil
        }
        let active: NSRange? = matches.indices.contains(selected) ? {
            let intersection = NSIntersectionRange(matches[selected], visible)
            return intersection.length > 0 ? NSRange(location: intersection.location - offset, length: intersection.length) : nil
        }() : nil
        VStack(spacing: 8) {
            if showFind {
                HStack(spacing: 8) {
                    TextField("Найти в этой ячейке", text: $query)
                        .textFieldStyle(.roundedBorder).focused($findFocused)
                        .onSubmit { move(1) }
                        .onExitCommand { showFind = false; query = "" }
                    if searching { ProgressView().controlSize(.small) }
                    else { Text(matches.isEmpty ? "0 из 0" : "\(selected + 1) из \(matches.count)").monospacedDigit() }
                    Button { move(-1) } label: { Image(systemName: "chevron.up") }.help("Предыдущее (⇧⌘G)").disabled(matches.isEmpty || searching)
                    Button { move(1) } label: { Image(systemName: "chevron.down") }.help("Следующее (⌘G / Enter)").disabled(matches.isEmpty || searching)
                    Button { showFind = false; query = "" } label: { Image(systemName: "xmark") }.help("Закрыть поиск (Esc)")
                }.font(.callout)
            }
            if pages.count > 1 {
                HStack {
                    Button("Назад") { page -= 1 }.disabled(page == 0)
                    Text("Часть \(page + 1) из \(pages.count)")
                    Button("Далее") { page += 1 }.disabled(page + 1 >= pages.count)
                    Spacer()
                }.font(.callout)
            }
            CodeText(text: pages[visiblePage], bracketState: JSONBracketState.before(pages.prefix(visiblePage)), fontSize: fontSize, highlight: highlight,
                     matches: localMatches, active: active, reveal: reveal)
        }
        .onAppear { if findRequest != nil { openFind() } }
        .onChange(of: findRequest) { _ in openFind() }
        .onReceive(NotificationCenter.default.publisher(for: .cellFindNext)) { _ in move(1) }
        .onReceive(NotificationCenter.default.publisher(for: .cellFindPrevious)) { _ in move(-1) }
        .task(id: SearchInput(query: query, pages: pages)) {
            page = min(page, pages.count - 1)
            matches = []; selected = 0
            guard !query.isEmpty else { searching = false; return }
            searching = true
            let needle = query, chunks = pages
            let worker = Task.detached(priority: .userInitiated) { () throws -> [NSRange] in
                let text = chunks.joined() as NSString
                var result: [NSRange] = [], position = 0
                while position < text.length {
                    try Task.checkCancellation()
                    let range = text.range(of: needle, options: [.caseInsensitive, .literal], range: NSRange(location: position, length: text.length - position))
                    if range.location == NSNotFound { break }
                    result.append(range); position = NSMaxRange(range)
                }
                return result
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                matches = result; searching = false; revealSelected()
            } catch { if !Task.isCancelled { searching = false } }
        }
    }
}

// Only a bounded page enters TextKit; formatting of the complete cell happens off the main thread.
private struct CodeText: NSViewRepresentable {
    let text: String
    let bracketState: JSONBracketState
    let fontSize: Double
    let highlight: Bool
    let matches: [NSRange]
    let active: NSRange?
    let reveal: UUID
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true
        view.isRichText = false
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.backgroundColor = JSONPalette.background
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        guard coordinator.text != text || coordinator.bracketState != bracketState || coordinator.fontSize != fontSize || coordinator.highlight != highlight || coordinator.matches != matches || coordinator.active != active || coordinator.reveal != reveal else { return }
        let shouldReveal = coordinator.reveal != reveal
        let changedText = coordinator.text != text
        let selection = view.selectedRange()
        coordinator.bracketState = bracketState
        coordinator.text = text; coordinator.fontSize = fontSize; coordinator.highlight = highlight
        coordinator.matches = matches; coordinator.active = active; coordinator.reveal = reveal
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let rendered = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: JSONPalette.text,
            .paragraphStyle: paragraph
        ])
        if highlight, let regex = Coordinator.tokens {
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let token = ns.substring(with: match.range)
                let color: NSColor
                if token.first == "\"" {
                    let end = NSMaxRange(match.range)
                    var next = end
                    while next < ns.length && [9, 10, 13, 32].contains(Int(ns.character(at: next))) { next += 1 }
                    color = next < ns.length && ns.character(at: next) == 58 ? JSONPalette.key : JSONPalette.string
                } else if ["true", "false", "null"].contains(token) { color = JSONPalette.literal }
                else { color = JSONPalette.number }
                rendered.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        if highlight {
            var state = bracketState
            for (offset, character) in text.utf16.enumerated() {
                if let depth = state.consume(character) {
                    rendered.addAttribute(.foregroundColor,
                        value: JSONPalette.brackets[depth % JSONPalette.brackets.count],
                        range: NSRange(location: offset, length: 1))
                }
            }
        }
        for range in matches { rendered.addAttribute(.backgroundColor, value: JSONPalette.key.withAlphaComponent(0.22), range: range) }
        if let active { rendered.addAttribute(.backgroundColor, value: JSONPalette.number.withAlphaComponent(0.45), range: active) }
        view.textStorage?.setAttributedString(rendered)
        if changedText { view.scrollToBeginningOfDocument(nil) }
        else if NSMaxRange(selection) <= rendered.length { view.setSelectedRange(selection) }
        if shouldReveal, let active {
            view.scrollRangeToVisible(active)
            view.showFindIndicator(for: active)
        }
    }
    final class Coordinator {
        var matches: [NSRange] = []
        var active: NSRange?
        var reveal: UUID?
        var text: String?
        var fontSize = 0.0
        var highlight = false
        var bracketState = JSONBracketState()
        static let tokens = try? NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|\b(?:true|false|null)\b|-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?"#)
    }
}

// Carry string/escape state across display pages so braces inside strings stay untouched.
private struct JSONBracketState: Equatable {
    var depth = 0
    var inString = false
    var escaped = false

    mutating func consume(_ character: UInt16) -> Int? {
        if inString {
            if escaped { escaped = false }
            else if character == 92 { escaped = true }
            else if character == 34 { inString = false }
            return nil
        }
        if character == 34 { inString = true }
        else if character == 123 || character == 91 {
            defer { depth += 1 }
            return depth
        } else if character == 125 || character == 93 {
            depth = max(0, depth - 1)
            return depth
        }
        return nil
    }

    static func before(_ pages: ArraySlice<String>) -> Self {
        var state = Self()
        for page in pages {
            for character in page.utf16 { _ = state.consume(character) }
        }
        return state
    }
}

private enum JSONPalette {
    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static let background = rgb(0x1E1E1E)
    static let text = rgb(0xD4D4D4)
    static let key = rgb(0x9CDCFE)
    static let string = rgb(0xCE9178)
    static let number = rgb(0xB5CEA8)
    static let brackets = [rgb(0xFFD700), rgb(0xDA70D6), rgb(0x179FFF)]
    static let literal = rgb(0x569CD6)
}

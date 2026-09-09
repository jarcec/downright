import AppKit
import MarkdownKit
import os

/// Owns the TextKit 2 stack for one document and keeps parse → decorate → render in
/// sync with edits and selection (TRD §3, §6.6).
@MainActor
public final class EditorController: NSObject, NSTextViewDelegate, @preconcurrency NSTextLayoutManagerDelegate, @preconcurrency NSTextStorageDelegate {
    public let textStorage: NSTextStorage
    public let contentStorage = NSTextContentStorage()
    public let layoutManager = NSTextLayoutManager()
    public let textContainer: NSTextContainer
    public let textView: MarkdownTextView
    public let scrollView: NSScrollView
    public var theme: Theme
    public var dialect: Dialect = .gfm

    public private(set) var document: Document
    public private(set) var lines: LineIndex
    public private(set) var engine: DecorationEngine

    private let storageDelegate = MarkdownContentStorageDelegate()
    private var pendingEdit: NSRange? = nil
    private var pendingDelta = 0
    private var flushScheduled = false
    private let log = Logger(subsystem: "com.jarcec.Downright", category: "editor")

    /// Debug counter for the TRD §6.6 budget: paragraphs invalidated by the last reveal change.
    public private(set) var lastRevealInvalidationCount = 0

    /// Fired after every reparse (typing, reload). Chrome such as the outline listens.
    public var onDocumentChange: (() -> Void)?
    /// Fired after every selection change and after reparses.
    public var onSelectionChange: (() -> Void)?

    public var revealAll = false {
        didSet {
            storageDelegate.revealAll = revealAll
            invalidate([NSRange(location: 0, length: textStorage.length)])
        }
    }

    public init(textStorage: NSTextStorage, theme: Theme = Theme()) {
        self.textStorage = textStorage
        self.theme = theme
        let text = textStorage.string
        self.document = MarkdownParser.parse(text, dialect: .gfm)
        self.lines = LineIndex(text)
        self.engine = DecorationEngine(document: document, lines: lines, theme: theme)

        textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.lineFragmentPadding = 0
        layoutManager.textContainer = textContainer
        contentStorage.textStorage = textStorage
        contentStorage.addTextLayoutManager(layoutManager)

        textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: textContainer)
        scrollView = NSScrollView(frame: textView.frame)
        super.init()

        storageDelegate.engine = engine
        contentStorage.delegate = storageDelegate
        layoutManager.delegate = self
        textStorage.delegate = self

        configureTextView()
        updateReveal()
    }

    private func configureTextView() {
        textView.controller = self
        textView.vim.controller = self
        textView.delegate = self
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.smartInsertDeleteEnabled = false
        // NSTextView's own ruler integration is TextKit 1-only; letting it touch the
        // ruler makes it access `layoutManager`, which silently downgrades the view to
        // TextKit 1 and detaches our stack. Our LineNumberRulerView never needs it.
        textView.usesRuler = false
        textView.isRulerVisible = false
        textView.font = theme.bodyFont
        textView.textColor = theme.textColor
        textView.typingAttributes = [.font: theme.bodyFont, .foregroundColor: theme.textColor]
        textView.linkTextAttributes = [.foregroundColor: theme.accentColor, .cursor: NSCursor.pointingHand]
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.autoresizingMask = [.width, .height]
    }

    // MARK: - Parse & invalidate

    /// Reparse everything and redraw. Used after programmatic replacement (reload).
    public func reparseAll() {
        pendingEdit = nil
        replaceDocument(with: MarkdownParser.parse(textStorage.string, dialect: dialect))
        updateReveal(extraInvalidation: [NSRange(location: 0, length: textStorage.length)])
        onDocumentChange?()
        onSelectionChange?()
    }

    private func replaceDocument(with doc: Document) {
        document = doc
        lines = LineIndex(textStorage.string)
        engine = DecorationEngine(document: document, lines: lines, theme: theme)
        storageDelegate.engine = engine
        // Carry the caret's table cell into the new engine so widths stay right while typing.
        let caret = textView.selectedRange().location
        if let h = tableHit(at: caret), let ci = h.cellIndex {
            engine.setRevealedCell(.init(blockStart: h.block.range.location, rowIndex: h.rowIndex, cellIndex: ci))
        }
    }

    // MARK: - Tables: hit-testing and editing

    public struct TableHit {
        public var block: Block
        public var table: Table
        /// Index into `table.allRows` (0 = header). `nil` when on the delimiter row.
        public var rowIndex: Int
        public var row: TableRow
        /// Cell containing the caret (caret at a cell boundary counts), else nil (in a separator).
        public var cellIndex: Int?
    }

    public func tableHit(at offset: Int) -> TableHit? {
        guard let block = document.path(containing: offset).last, case .table(let table) = block.kind else { return nil }
        let rows = table.allRows
        guard let ri = rows.firstIndex(where: { $0.range.location <= offset && offset <= $0.range.end }) else { return nil }
        let row = rows[ri]
        let ci = row.cells.firstIndex { $0.range.location <= offset && offset <= $0.range.end }
        return TableHit(block: block, table: table, rowIndex: ri, row: row, cellIndex: ci)
    }

    public func isOnTableDelimiter(_ offset: Int) -> Bool {
        guard let block = document.path(containing: offset).last, case .table(let t) = block.kind else { return false }
        return t.delimiterRow.location <= offset && offset <= t.delimiterRow.end
    }

    /// Tab / ⇧Tab inside a table: select the next / previous cell's content.
    func tableTab(at offset: Int, forward: Bool) -> Bool {
        guard let h = tableHit(at: offset) else { return false }
        let rows = h.table.allRows
        var ri = h.rowIndex
        var ci = h.cellIndex ?? (forward ? -1 : h.row.cells.count)
        if forward {
            ci += 1
            if ci >= rows[ri].cells.count { ri += 1; ci = 0 }
            guard ri < rows.count, ci < rows[ri].cells.count else { return true }
        } else {
            ci -= 1
            if ci < 0 { ri -= 1; guard ri >= 0 else { return true }; ci = rows[ri].cells.count - 1 }
            guard ci >= 0 else { return true }
        }
        textView.setSelectedRange(rows[ri].cells[ci].range)
        textView.scrollRangeToVisible(rows[ri].cells[ci].range)
        return true
    }

    /// Return inside a table: insert an empty row below the current one (below the delimiter
    /// when on the header) and put the caret in its first cell.
    func tableInsertRow(at offset: Int) -> Bool {
        guard let h = tableHit(at: offset) else { return false }
        let ns = textStorage.string as NSString
        let leadingPipe = h.table.header.separators.first.map { $0.length > 0 } ?? true
        let trailingPipe = h.table.header.separators.last.map { $0.length > 0 } ?? true
        let columns = h.table.columnCount
        var template = leadingPipe ? "| " : ""
        template += Array(repeating: " ", count: max(1, columns)).joined(separator: " | ")
        template += trailingPipe ? " |" : ""
        let insertLine = h.rowIndex == 0 ? h.table.delimiterRow : h.row.range
        let lineEnd = insertLine.end
        let needsNewlineAfter = lineEnd >= ns.length || ns.character(at: lineEnd) != 10
        let insertion = "\n" + template + (needsNewlineAfter ? "" : "")
        let at = NSRange(location: lineEnd, length: 0)
        guard textView.shouldChangeText(in: at, replacementString: insertion) else { return false }
        textStorage.replaceCharacters(in: at, with: insertion)
        textView.didChangeText()
        let caret = lineEnd + 1 + (leadingPipe ? 2 : 0)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        return true
    }

    /// After a horizontal move, keep the caret out of concealed table structure: snap to
    /// the adjacent cell boundary in the direction of travel.
    func snapCaretOutOfSeparator(movingRight: Bool) {
        let loc = textView.selectedRange().location
        guard textView.selectedRange().length == 0, let h = tableHit(at: loc), h.cellIndex == nil else { return }
        let cells = h.row.cells
        if movingRight {
            if let next = cells.first(where: { $0.range.location > loc }) { textView.setSelectedRange(NSRange(location: next.range.location, length: 0)) }
            else if let last = cells.last { textView.setSelectedRange(NSRange(location: last.range.end, length: 0)) }
        } else {
            if let prev = cells.last(where: { $0.range.end < loc }) { textView.setSelectedRange(NSRange(location: prev.range.end, length: 0)) }
            else if let first = cells.first { textView.setSelectedRange(NSRange(location: first.range.location, length: 0)) }
        }
    }

    private func flushPendingEdit() {
        flushScheduled = false
        guard let edit = pendingEdit else { return }
        pendingEdit = nil
        let delta = pendingDelta
        pendingDelta = 0
        let old = document
        let t = CFAbsoluteTimeGetCurrent()
        replaceDocument(with: MarkdownParser.parse(textStorage.string, dialect: dialect))
        let dirty = Self.dirtyRange(old: old, new: document, edit: edit, delta: delta)
        updateReveal(extraInvalidation: [dirty])
        let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
        if ms > 8 { log.debug("reparse \(self.textStorage.length) chars: \(ms, format: .fixed(precision: 1)) ms; dirty \(dirty.location)+\(dirty.length)") }
        onDocumentChange?()
        onSelectionChange?()
    }

    /// Smallest top-level range whose block structure may have changed: from the block
    /// containing the edit to the first following block that re-synchronises with the old
    /// parse (same kind, same range shifted by the edit delta). Plan §4 2f at block level.
    static func dirtyRange(old: Document, new: Document, edit: NSRange, delta: Int) -> NSRange {
        let newLen = new.length
        func firstIndex(_ blocks: [Block], reaching offset: Int) -> Int? {
            blocks.firstIndex { $0.range.location + $0.range.length > offset }
        }
        let editStart = edit.location
        var start = editStart
        let iNew = firstIndex(new.blocks, reaching: editStart)
        let iOld = firstIndex(old.blocks, reaching: editStart)
        if let i = iNew { start = min(start, new.blocks[i].range.location) }
        if let j = iOld { start = min(start, old.blocks[j].range.location) }
        // Include the previous block too: a new line can turn a paragraph into a setext heading
        if let i = iNew, i > 0 { start = min(start, new.blocks[i - 1].range.location) }
        if let j = iOld, j > 0 { start = min(start, old.blocks[j - 1].range.location) }

        var end = newLen
        if let j = iOld {
            let oldEditEnd = edit.location + max(0, edit.length - delta)
            var shifted = Set<String>()
            for b in old.blocks[j...] where b.range.location >= oldEditEnd {
                shifted.insert("\(b.range.location + delta)|\(b.range.length)|\(b.kind.label)")
            }
            if let i = iNew {
                for b in new.blocks[(i + 1)...] where shifted.contains("\(b.range.location)|\(b.range.length)|\(b.kind.label)") {
                    end = b.range.location
                    break
                }
            }
        }
        start = max(0, min(start, newLen))
        end = max(start, min(end, newLen))
        return NSRange(location: start, length: end - start)
    }

    private func invalidate(_ ranges: [NSRange]) {
        let merged = RevealPolicy.merge(ranges.filter { $0.length > 0 })
        guard !merged.isEmpty else { return }
        var clippedRanges: [NSRange] = []
        contentStorage.performEditingTransaction {
            for r in merged {
                let clipped = NSRange(location: min(r.location, textStorage.length), length: min(r.length, textStorage.length - min(r.location, textStorage.length)))
                if clipped.length > 0 {
                    textStorage.edited(.editedAttributes, range: clipped, changeInLength: 0)
                    clippedRanges.append(clipped)
                }
            }
        }
        // Lay the changed paragraphs out now, so anything reading caret geometry in this
        // run-loop turn (the insertion indicator in particular) sees fresh fragments.
        for r in clippedRanges where r.length < 20_000 {
            if let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: r.location),
               let end = contentStorage.location(start, offsetBy: r.length),
               let range = NSTextRange(location: start, end: end) {
                layoutManager.ensureLayout(for: range)
            }
        }
        textView.needsDisplay = true
        // The indicator was positioned before the relayout; refresh it once layout settled.
        // Without this the caret vanished when moving onto a line adjacent to a heading.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.textView.window?.firstResponder === self.textView else { return }
            self.textView.updateInsertionPointStateAndRestartTimer(true)
        }
    }

    private func updateReveal(extraInvalidation: [NSRange] = []) {
        let selections = textView.selectedRanges.map { $0.rangeValue }
        let newRevealed = RevealPolicy.revealedRanges(selections: selections, document: document, lines: lines)
        let oldRevealed = storageDelegate.revealed
        storageDelegate.revealed = newRevealed
        let caret = textView.selectedRange().location
        storageDelegate.selectionLocation = caret
        var toInvalidate = extraInvalidation
        if newRevealed != oldRevealed {
            // Only paragraphs entering or leaving the revealed set change appearance
            toInvalidate += Self.symmetricDifference(oldRevealed, newRevealed)
        }
        // Tables: the caret's cell decides what reveals and how wide its column is.
        let hit = tableHit(at: caret)
        let newCell = hit.flatMap { h in h.cellIndex.map { DecorationEngine.RevealedCell(blockStart: h.block.range.location, rowIndex: h.rowIndex, cellIndex: $0) } }
        if newCell != engine.revealedCell {
            if let old = engine.revealedCell, let block = document.path(containing: old.blockStart).last(where: { if case .table = $0.kind { return true }; return false }) {
                toInvalidate.append(block.range)
            }
            engine.setRevealedCell(newCell)
            if let h = hit { toInvalidate.append(h.block.range) }
        } else if let h = hit {
            toInvalidate.append(lines.paragraphRange(ofLine: lines.line(containing: caret)))
            _ = h
        }
        lastRevealInvalidationCount = toInvalidate.reduce(0) { $0 + max(1, $1.length / 40) }
        invalidate(toInvalidate)
    }

    static func symmetricDifference(_ a: [NSRange], _ b: [NSRange]) -> [NSRange] {
        // Small inputs: return both sides minus exact matches. Overlapping-but-unequal
        // ranges invalidate whole; cheap and correct.
        let sa = Set(a.map { "\($0.location)|\($0.length)" })
        let sb = Set(b.map { "\($0.location)|\($0.length)" })
        return a.filter { !sb.contains("\($0.location)|\($0.length)") } + b.filter { !sa.contains("\($0.location)|\($0.length)") }
    }

    // MARK: - NSTextStorageDelegate

    public func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                            range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        pendingEdit = pendingEdit.map { NSUnionRange($0, editedRange) } ?? editedRange
        pendingDelta += delta
        if !flushScheduled {
            flushScheduled = true
            DispatchQueue.main.async { [weak self] in self?.flushPendingEdit() }
        }
    }

    // MARK: - NSTextViewDelegate

    public func textDidChange(_ notification: Notification) {
        flushPendingEdit()
        textView.updateBlockCursor()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard pendingEdit == nil else { return }   // the edit flush recomputes reveal itself
        updateReveal()
        onSelectionChange?()
    }

    // MARK: - Geometry

    /// Caret rectangle (zero width) for `offset`, in text view coordinates.
    func caretRect(at offset: Int) -> NSRect? {
        guard let loc = contentStorage.location(contentStorage.documentRange.location, offsetBy: min(offset, textStorage.length)) else { return nil }
        var rect: NSRect? = nil
        layoutManager.enumerateTextSegments(in: NSTextRange(location: loc), type: .selection, options: [.rangeNotRequired]) { _, frame, _, _ in
            rect = frame; return false
        }
        guard var r = rect else { return nil }
        r.origin.x += textView.textContainerInset.width
        r.origin.y += textView.textContainerInset.height
        return r
    }

    /// Advance width of the character at `offset` in the current layout, or nil at a line
    /// end / document end. Used for vim's block cursor.
    func characterWidth(at offset: Int) -> CGFloat? {
        guard offset < textStorage.length,
              let loc = contentStorage.location(contentStorage.documentRange.location, offsetBy: offset),
              let fragment = layoutManager.textLayoutFragment(for: loc),
              let elementRange = fragment.textElement?.elementRange else { return nil }
        let local = contentStorage.offset(from: elementRange.location, to: loc)
        guard let lf = fragment.textLineFragments.first(where: { $0.characterRange.contains(local) }) else { return nil }
        let ch = (textStorage.string as NSString).character(at: offset)
        if ch == 10 { return nil }
        let a = lf.locationForCharacter(at: local).x
        let b = lf.locationForCharacter(at: local + 1).x
        return b - a
    }

    // MARK: - Statistics (status bar)

    public struct Statistics: Equatable {
        public var lines: Int
        public var words: Int
        public var characters: Int
        public init(lines: Int, words: Int, characters: Int) { self.lines = lines; self.words = words; self.characters = characters }
    }

    /// Whole-document counts. O(n); called after each reparse, not per keystroke.
    public func statistics() -> Statistics {
        var words = 0
        var inWord = false
        for u in textStorage.string.utf16 {
            let ws = u == 32 || u == 10 || u == 9 || u == 13 || u == 0xA0
            if ws { inWord = false } else if !inWord { inWord = true; words += 1 }
        }
        return Statistics(lines: lines.lineCount, words: words, characters: textStorage.length)
    }

    /// 1-based caret line and column (UTF-16 units from the line start).
    public func caretPosition() -> (line: Int, column: Int) {
        let loc = min(textView.selectedRange().location, textStorage.length)
        let li = lines.line(containing: loc)
        return (li + 1, loc - lines.lineStarts[li] + 1)
    }

    /// Extensions the current document uses (PRD §8 detection).
    public var detectedDialect: DetectedDialect { DetectedDialect.detect(in: document) }

    // MARK: - Outline support

    public struct Heading: Equatable {
        public var level: Int
        public var title: String
        public var offset: Int
    }

    /// Headings in document order, including those nested in containers.
    public func headings() -> [Heading] {
        var out: [Heading] = []
        let source = textStorage.string
        func walk(_ blocks: [Block]) {
            for b in blocks {
                switch b.kind {
                case .heading(let level), .setextHeading(let level, _):
                    let title = b.contentRanges.map { (source as NSString).substring(with: $0) }.joined(separator: " ")
                    out.append(Heading(level: level, title: Self.stripInlineMarkers(title), offset: b.range.location))
                default:
                    break
                }
                walk(b.children)
            }
        }
        walk(document.blocks)
        return out
    }

    /// Cheap cleanup for outline titles: drop emphasis/code markers, keep link text.
    static func stripInlineMarkers(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        t = t.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "~~", with: "")
        if let re = try? NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\([^)]*\\)") {
            t = re.stringByReplacingMatches(in: t, range: NSRange(location: 0, length: t.utf16.count), withTemplate: "$1")
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Place the caret at `offset` and scroll so that line sits near the top.
    public func scroll(to offset: Int) {
        let target = NSRange(location: min(offset, textStorage.length), length: 0)
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        guard let loc = contentStorage.location(contentStorage.documentRange.location, offsetBy: target.location),
              let fragment = layoutManager.textLayoutFragment(for: loc) else { return }
        let y = fragment.layoutFragmentFrame.minY + textView.textContainerInset.height - 24
        textView.scroll(NSPoint(x: 0, y: max(0, y)))
        textView.window?.makeFirstResponder(textView)
    }

    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let u = link as? URL { url = u } else if let s = link as? String { url = URL(string: s) } else { url = nil }
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "file"].contains(scheme) else { return true }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: - NSTextLayoutManagerDelegate

    public func textLayoutManager(_ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
                                  in textElement: NSTextElement) -> NSTextLayoutFragment {
        let fragment = DecoratedLayoutFragment(textElement: textElement, range: textElement.elementRange)
        fragment.theme = theme
        guard let range = textElement.elementRange else { return fragment }
        let offset = contentStorage.offset(from: contentStorage.documentRange.location, to: range.location)
        let length = contentStorage.offset(from: range.location, to: range.endLocation)
        let d = engine.decoration(forParagraphAt: offset)
        let revealed = storageDelegate.isRevealed(NSRange(location: offset, length: length))
        fragment.quoteDepth = d.quoteDepth
        fragment.appearance = Self.appearance(for: d.role, revealed: revealed, at: offset, length: length)
        return fragment
    }

    private static func appearance(for role: BlockRole, revealed: Bool, at offset: Int, length: Int) -> DecoratedLayoutFragment.Appearance {
        switch role {
        case .none, .heading, .html:
            return .plain
        case .tableRow(let boundaries, let header, let first, let last):
            return .table(boundaries: boundaries, header: header, top: first, bottom: last)
        case .tableDelimiter:
            return .hidden
        case .fenceOpen(let info):
            return revealed ? .codeBlock(info: info, top: true, bottom: false) : .hidden
        case .fenceClose:
            return revealed ? .codeBlock(info: "", top: false, bottom: true) : .hidden
        case .codeLine(let info, let first, let last):
            // When revealed, the fence lines carry the rounded corners and the label instead
            return .codeBlock(info: revealed ? "" : info, top: first && !revealed, bottom: last && !revealed)
        case .indentedCode(let first, let last):
            return .codeBlock(info: "", top: first, bottom: last)
        case .setextUnderline:
            return revealed ? .plain : .hidden
        case .thematicBreak:
            return revealed ? .plain : .rule
        case .frontmatter(let first, let last):
            return .frontmatter(top: first, bottom: last)
        }
    }

    // MARK: - Interactions used by the text view

    /// Source offset for a point in the text view's coordinates.
    func characterIndex(at point: NSPoint) -> Int? {
        let p = CGPoint(x: point.x - textView.textContainerInset.width, y: point.y - textView.textContainerInset.height)
        guard let fragment = layoutManager.textLayoutFragment(for: p) else { return nil }
        let local = CGPoint(x: p.x - fragment.layoutFragmentFrame.origin.x, y: p.y - fragment.layoutFragmentFrame.origin.y)
        guard let lf = fragment.textLineFragments.first(where: { $0.typographicBounds.contains(CGPoint(x: max($0.typographicBounds.minX, local.x), y: local.y)) }) ?? fragment.textLineFragments.first else { return nil }
        let idx = lf.characterIndex(for: local)
        guard idx != NSNotFound, let elementRange = fragment.textElement?.elementRange else { return nil }
        return contentStorage.offset(from: contentStorage.documentRange.location, to: elementRange.location) + idx
    }

    /// Toggle a task checkbox if `offset` lands on one in a concealed paragraph.
    func toggleTask(at offset: Int) -> Bool {
        let d = engine.decoration(forParagraphAt: offset)
        guard let task = d.task, task.range.contains(offset) else { return false }
        let li = lines.line(containing: offset)
        guard !storageDelegate.isRevealed(lines.paragraphRange(ofLine: li)) else { return false }
        let inner = NSRange(location: task.range.location + 1, length: 1)
        let replacement = task.checked ? " " : "x"
        guard textView.shouldChangeText(in: inner, replacementString: replacement) else { return false }
        textStorage.replaceCharacters(in: inner, with: replacement)
        textView.didChangeText()
        return true
    }

    /// Return inside a list item: continue the list, or end it when the item is empty.
    func continueList(at offset: Int, in tv: NSTextView) -> Bool {
        let li = lines.line(containing: offset)
        let cr = lines.contentRange(ofLine: li)
        guard offset == cr.location + cr.length else { return false }      // only at end of line
        guard let item = document.path(containing: cr.location).last(where: { if case .listItem = $0.kind { return true }; return false }),
              case .listItem(let marker, _, let task) = item.kind, item.range.location == lines.lineStarts[li] else { return false }
        let ns = textStorage.string as NSString
        let afterMarker = (task?.range.end ?? marker.end)
        let content = ns.substring(with: NSRange(location: afterMarker, length: max(0, cr.end - afterMarker))).trimmingCharacters(in: .whitespaces)
        if content.isEmpty {
            // Empty item: remove the marker, ending the list
            let r = NSRange(location: cr.location, length: cr.length)
            guard tv.shouldChangeText(in: r, replacementString: "") else { return false }
            textStorage.replaceCharacters(in: r, with: "")
            tv.didChangeText()
            return true
        }
        let leading = ns.substring(with: NSRange(location: cr.location, length: marker.location - cr.location))
        let markerText = ns.substring(with: marker)
        var next = markerText
        if let digits = Int(markerText.dropLast()), let delim = markerText.last { next = "\(digits + 1)\(delim)" }
        let prefix = "\n" + leading + next + " " + (task != nil ? "[ ] " : "")
        tv.insertText(prefix, replacementRange: NSRange(location: offset, length: 0))
        return true
    }

    /// Tab / Shift-Tab on a list item line: indent or outdent by two spaces.
    func indentListItem(at offset: Int, by direction: Int, in tv: NSTextView) -> Bool {
        let li = lines.line(containing: offset)
        let cr = lines.contentRange(ofLine: li)
        guard document.path(containing: cr.location).contains(where: { if case .listItem = $0.kind { return true }; return false }) else { return false }
        if direction > 0 {
            tv.insertText("  ", replacementRange: NSRange(location: cr.location, length: 0))
        } else {
            let ns = textStorage.string as NSString
            var n = 0
            while n < 2 && cr.location + n < cr.end && ns.character(at: cr.location + n) == 32 { n += 1 }
            guard n > 0 else { return true }
            let r = NSRange(location: cr.location, length: n)
            guard tv.shouldChangeText(in: r, replacementString: "") else { return false }
            textStorage.replaceCharacters(in: r, with: "")
            tv.didChangeText()
        }
        return true
    }
}


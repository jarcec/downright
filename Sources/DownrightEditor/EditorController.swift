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
    }

    private func replaceDocument(with doc: Document) {
        document = doc
        lines = LineIndex(textStorage.string)
        engine = DecorationEngine(document: document, lines: lines, theme: theme)
        storageDelegate.engine = engine
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
        contentStorage.performEditingTransaction {
            for r in merged {
                let clipped = NSRange(location: min(r.location, textStorage.length), length: min(r.length, textStorage.length - min(r.location, textStorage.length)))
                if clipped.length > 0 { textStorage.edited(.editedAttributes, range: clipped, changeInLength: 0) }
            }
        }
        textView.needsDisplay = true
    }

    private func updateReveal(extraInvalidation: [NSRange] = []) {
        let selections = textView.selectedRanges.map { $0.rangeValue }
        let newRevealed = RevealPolicy.revealedRanges(selections: selections, document: document, lines: lines)
        let oldRevealed = storageDelegate.revealed
        storageDelegate.revealed = newRevealed
        var toInvalidate = extraInvalidation
        if newRevealed != oldRevealed {
            // Only paragraphs entering or leaving the revealed set change appearance
            toInvalidate += Self.symmetricDifference(oldRevealed, newRevealed)
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
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard pendingEdit == nil else { return }   // the edit flush recomputes reveal itself
        updateReveal()
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
        case .none, .heading, .html, .tableRow:
            return .plain
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


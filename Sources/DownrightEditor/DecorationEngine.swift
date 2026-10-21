import AppKit
import MarkdownKit

/// Maps a parsed `Document` to per-line `ParagraphDecoration`s. Immutable per document
/// version; the controller replaces it after every reparse, which also drops the cache.
@MainActor
public final class DecorationEngine {
    public let document: Document
    public let lines: LineIndex
    public let theme: Theme
    /// Raw Markdown mode: monospace source with colour hints only — no typography, block
    /// decorations, substitutions or table layout.
    public let sourceMode: Bool
    /// Bitmaps behind `![alt](src)`; nil renders images as their dimmed source.
    public let images: ImageLoader?
    /// The document's own URL, which relative image paths resolve against.
    public let baseURL: URL?
    /// Draws ```mermaid blocks; nil leaves them as code.
    public let diagrams: DiagramRenderer?
    /// Lines inside folded sections (set by the controller before decorations are built).
    public var hiddenLines: Set<Int> = [] { didSet { cache.removeAll() } }
    private var cache: [Int: ParagraphDecoration] = [:]
    private var tableLayouts: [Int: TableLayout] = [:]
    /// Paragraph starts of the built lines that show each image, so a load or a width
    /// change rebuilds exactly those.
    private var imageSites: [URL: Set<Int>] = [:]
    /// Paragraph starts of the built fence lines showing each diagram, by renderer key.
    private var diagramSites: [String: Set<Int>] = [:]
    /// Highlight tokens per fenced code block (absolute source ranges), keyed by block start.
    private var codeTokens: [Int: [(NSRange, CodeToken)]] = [:]
    private let spaceWidth: CGFloat

    /// The table cell under the caret, identified by table block start, row index into
    /// `allRows`, and cell index. It is measured with its markers visible so the column
    /// widens instead of the text overflowing.
    public private(set) var revealedCell: RevealedCell? = nil
    public struct RevealedCell: Equatable {
        public var blockStart: Int
        public var rowIndex: Int
        public var cellIndex: Int
        public init(blockStart: Int, rowIndex: Int, cellIndex: Int) { self.blockStart = blockStart; self.rowIndex = rowIndex; self.cellIndex = cellIndex }
    }

    public func setRevealedCell(_ cell: RevealedCell?) {
        guard cell != revealedCell else { return }
        for start in [revealedCell?.blockStart, cell?.blockStart].compactMap({ $0 }) {
            tableLayouts[start] = nil
            if let block = document.path(containing: start).last(where: { if case .table = $0.kind { return true }; return false }) {
                for key in cache.keys where block.range.contains(key) { cache[key] = nil }
            }
        }
        revealedCell = cell
    }
    /// Horizontal padding on each side of a cell's text.
    nonisolated static let cellGutter: CGFloat = 10

    // MARK: - Table scrolling

    /// Width of the text column, the viewport a wide table scrolls within. Infinite until
    /// the controller sets it.
    public private(set) var columnWidth: CGFloat = .greatestFiniteMagnitude
    /// Requested horizontal offset per table (block start). Clamped to the table's
    /// overflow when read, so a window that grows reveals the table again.
    private var tableScrolls: [Int: CGFloat] = [:]

    /// Sets the column width and returns the ranges of the scrolled tables whose
    /// effective offset changed with it, plus every paragraph showing an image, which
    /// is sized to the column.
    @discardableResult
    public func setColumnWidth(_ width: CGFloat) -> [NSRange] {
        guard abs(width - columnWidth) > 0.5 else { return [] }
        let before = tableScrolls.keys.map { ($0, tableScroll(blockStart: $0)) }
        columnWidth = width
        return before.compactMap { start, old in
            abs(tableScroll(blockStart: start) - old) > 0.5 ? tableBlock(at: start)?.range : nil
        } + dropImageParagraphs() + dropDiagramParagraphs()
    }

    // MARK: - Images

    /// Forget the built decorations of the paragraphs showing `url` (every image when
    /// nil) and return their ranges for the controller to relay out. A paragraph inside
    /// a table takes its whole table with it: the image sets its column's width.
    @discardableResult
    public func dropImageParagraphs(for url: URL? = nil) -> [NSRange] {
        let keys: Set<Int> = url.map { imageSites[$0] ?? [] } ?? imageSites.values.reduce(into: Set()) { $0.formUnion($1) }
        if let url { imageSites[url] = nil } else { imageSites.removeAll() }
        var out: [NSRange] = []
        for k in keys {
            if let table = tableBlock(at: k) {
                tableLayouts[table.range.location] = nil
                for key in cache.keys where table.range.contains(key) { cache[key] = nil }
                out.append(table.range)
            } else {
                cache[k] = nil
                out.append(lines.paragraphRange(ofLine: lines.line(containing: k)))
            }
        }
        return out
    }

    /// Forget the built fence lines showing the diagram with `key` (every diagram when
    /// nil) and return their ranges for the controller to relay out.
    @discardableResult
    public func dropDiagramParagraphs(for key: String? = nil) -> [NSRange] {
        let keys: Set<Int> = key.map { diagramSites[$0] ?? [] } ?? diagramSites.values.reduce(into: Set()) { $0.formUnion($1) }
        if let key { diagramSites[key] = nil } else { diagramSites.removeAll() }
        return keys.map { k in
            cache[k] = nil
            return lines.paragraphRange(ofLine: lines.line(containing: k))
        }
    }

    /// The source of a ```mermaid block, or nil when it is not one this engine draws
    /// (no renderer, Raw mode, or nothing between the fences yet).
    private func diagramSource(_ block: Block, info: String) -> String? {
        guard diagrams != nil, !sourceMode, DiagramRenderer.isDiagram(info: info) else { return nil }
        let src = document.sourceString as NSString
        let text = block.contentRanges.map { src.substring(with: $0) }.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// While concealed, the opening fence of a diagram shows the diagram: its first
    /// character becomes the attachment, the rest of the line is hidden, and the source
    /// lines below collapse. Revealed, the block is ordinary code.
    private func diagramFence(_ source: String, line cr: NSRange, fence: NSRange, into d: inout ParagraphDecoration) {
        guard let diagrams else { return }
        let (key, state) = diagrams.diagram(for: source, theme: theme)
        diagramSites[key, default: []].insert(cr.location)
        let image: NSImage
        var tip: String? = nil
        switch state {
        case .rendered(let img): image = img
        case .rendering: image = placeholder(symbol: "flowchart", text: "Drawing diagram…")
        case .failed(let message):
            image = placeholder(symbol: "exclamationmark.triangle", text: "Diagram error")
            tip = message
        }
        let at = fence.location
        attach(image, at: at, maxWidth: columnWidth - d.headIndent, into: &d)
        if let tip { d.concealedStyles.append(StyleRun(NSRange(location: at, length: 1), .toolTip(tip))) }
        if at > cr.location { d.conceal.append(NSRange(location: cr.location, length: at - cr.location)) }
        if cr.end > at + 1 { d.conceal.append(NSRange(location: at + 1, length: cr.end - at - 1)) }
    }

    /// Show `image` on the character at `offset` while concealed, scaled down to fit
    /// `maxWidth` (never up).
    private func attach(_ image: NSImage, at offset: Int, maxWidth: CGFloat, into d: inout ParagraphDecoration) {
        var size = image.size
        if columnWidth < 1e6 {
            let fit = max(48, maxWidth)
            if size.width > fit { size = CGSize(width: fit, height: size.height * fit / size.width) }
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: size)
        attachment.allowsTextAttachmentView = false   // drawn by the layout fragment, like any glyph
        let first = NSRange(location: offset, length: 1)
        d.substitutions.append((offset, 0xFFFC))
        d.concealedStyles.append(StyleRun(first, .font(theme.bodyFont)))
        d.concealedStyles.append(StyleRun(first, .attachment(attachment)))
        d.concealedLineHeightMultiple = 1
    }

    /// Replace the image construct with its bitmap while concealed: the `!` becomes the
    /// attachment character and carries the image, the rest of `![alt](src)` is hidden.
    /// Revealed, the source shows and the image does not (PRD §7.2).
    private func imageInline(_ r: NSRange, destination: String, alt: String, cr: NSRange, into d: inout ParagraphDecoration) {
        guard let images, !sourceMode, cr.contains(r.location) else { return }
        let url = ImageLoader.resolve(destination, baseURL: baseURL)
        let name = (destination as NSString).lastPathComponent
        let label = alt.isEmpty ? name : alt
        let image: NSImage
        switch url.map({ images.image(for: $0) }) {
        case .loaded(let img)?: image = img
        case .loading?: image = placeholder(symbol: "photo", text: label)
        case .remote?: image = placeholder(symbol: "globe", text: label)
        case .failed?, nil: image = placeholder(symbol: "exclamationmark.triangle", text: alt.isEmpty ? name : "\(alt) (\(name))")
        }
        if let url { imageSites[url, default: []].insert(lines.lineStarts[lines.line(containing: r.location)]) }

        attach(image, at: r.location, maxWidth: columnWidth - d.headIndent, into: &d)
        if let rest = NSRange(location: r.location + 1, length: r.length - 1).intersection(cr), rest.length > 0 { d.conceal.append(rest) }
    }

    /// A pill standing in for an image that is loading, blocked or missing.
    private func placeholder(symbol: String, text: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: theme.bodySize * 0.85)
        let fg = theme.secondaryColor, bg = theme.codeBackground
        let label = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fg])
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular).applying(.init(paletteColors: [fg])))
        let pad: CGFloat = 8, gap: CGFloat = 6
        let iconSize = icon?.size ?? .zero
        let labelSize = label.size()
        let size = CGSize(width: ceil(pad + iconSize.width + (icon == nil ? 0 : gap) + labelSize.width + pad),
                          height: ceil(max(labelSize.height, iconSize.height) + 8))
        return NSImage(size: size, flipped: false) { rect in
            bg.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            var x = pad
            if let icon {
                icon.draw(in: CGRect(x: x, y: (rect.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
                x += iconSize.width + gap
            }
            label.draw(at: CGPoint(x: x, y: (rect.height - labelSize.height) / 2))
            return true
        }
    }

    /// How far the table starting at `blockStart` can scroll: its width past the column.
    public func tableScrollLimit(blockStart: Int) -> CGFloat {
        guard let block = tableBlock(at: blockStart), case .table(let t) = block.kind,
              t.allRows.allSatisfy({ ($0.separators.first?.length ?? 0) > 0 }) else { return 0 }   // rows without a leading pipe cannot shift
        let width = tableLayout(for: t, blockStart: blockStart).boundaries.last ?? 0
        return max(0, width + 1 - columnWidth)
    }

    /// The table's effective horizontal offset.
    public func tableScroll(blockStart: Int) -> CGFloat {
        guard let wanted = tableScrolls[blockStart], wanted > 0 else { return 0 }
        return min(wanted, tableScrollLimit(blockStart: blockStart))
    }

    /// Offset for the table containing `offset`; 0 elsewhere.
    public func tableScroll(containing offset: Int) -> CGFloat {
        guard !tableScrolls.isEmpty, !sourceMode else { return 0 }
        for (start, wanted) in tableScrolls where wanted > 0 {
            if let block = tableBlock(at: start), block.range.contains(offset) { return tableScroll(blockStart: start) }
        }
        return 0
    }

    /// For the text container: nil unless the line at `offset` belongs to a rendered
    /// table, else that table's offset. Reads the (cached) decoration, so it costs nothing
    /// beyond the layout already paying for it.
    public func tableLineShift(at offset: Int) -> CGFloat? {
        guard !sourceMode else { return nil }
        switch decoration(forParagraphAt: offset).role {
        case .tableRow, .tableDelimiter: return tableScroll(containing: offset)
        default: return nil
        }
    }

    /// Returns whether the effective offset changed.
    @discardableResult
    public func setTableScroll(blockStart: Int, to offset: CGFloat) -> Bool {
        let old = tableScroll(blockStart: blockStart)
        tableScrolls[blockStart] = max(0, offset)
        return abs(tableScroll(blockStart: blockStart) - old) > 0.5
    }

    /// Scrolls the table so the given cell is inside the column — or, for a cell wider
    /// than the column, so the caret (at `caretX`, in unscrolled table coordinates) is,
    /// with some room around it. Returns whether the table moved.
    public func revealTableCell(blockStart: Int, cellIndex: Int, caretX: CGFloat?) -> Bool {
        guard tableScrollLimit(blockStart: blockStart) > 0, let block = tableBlock(at: blockStart), case .table(let t) = block.kind else { return false }
        let b = tableLayout(for: t, blockStart: blockStart).boundaries
        guard cellIndex + 1 < b.count else { return false }
        var s = tableScroll(blockStart: blockStart)
        let left = b[cellIndex], right = b[cellIndex + 1] + 1
        if right - left <= columnWidth {
            if right > s + columnWidth { s = right - columnWidth }
            if left < s { s = left }
        } else if let x = caretX {
            let room: CGFloat = 48
            if x + room > s + columnWidth { s = x + room - columnWidth }
            if x - room < s { s = x - room }
        }
        return setTableScroll(blockStart: blockStart, to: s)
    }

    private func tableBlock(at start: Int) -> Block? {
        document.path(containing: start).last(where: { if case .table = $0.kind { return true }; return false })
    }

    public init(document: Document, lines: LineIndex, theme: Theme, sourceMode: Bool = false, images: ImageLoader? = nil, baseURL: URL? = nil, diagrams: DiagramRenderer? = nil) {
        self.document = document
        self.lines = lines
        self.theme = theme
        self.sourceMode = sourceMode
        self.diagrams = diagrams
        self.images = images
        self.baseURL = baseURL
        self.spaceWidth = theme.spaceWidth
    }

    public func decoration(forParagraphAt location: Int) -> ParagraphDecoration {
        let li = lines.line(containing: location)
        let key = lines.lineStarts[li]
        if let hit = cache[key] { return hit }
        var d = build(line: li)
        if sourceMode { d = Self.asSource(d, theme: theme, paragraph: lines.paragraphRange(ofLine: li)) }
        cache[key] = d
        return d
    }

    /// Strip a decoration down to what Raw mode shows: monospace text, colour hints
    /// (links, markers, code tokens), nothing concealed, no block layout.
    static func asSource(_ d: ParagraphDecoration, theme: Theme, paragraph pr: NSRange) -> ParagraphDecoration {
        var out = ParagraphDecoration()
        out.styles = [StyleRun(pr, .font(theme.monoFont)), StyleRun(pr, .foreground(theme.textColor))]
        for run in d.styles {
            switch run.op {
            case .foreground, .link, .strikethrough, .toolTip: out.styles.append(run)
            default: break
            }
        }
        // Markers always tinted (nothing is concealed in this mode).
        for run in d.markerStyles { out.styles.append(run) }
        for r in d.conceal + d.alwaysConceal where !d.markerStyles.contains(where: { $0.range == r }) {
            out.styles.append(StyleRun(r, .foreground(theme.markerColor)))
        }
        out.lineHeightMultiple = theme.lineHeightMultiple
        out.listItem = d.listItem
        out.cellRanges = []
        return out
    }

    // MARK: - Build

    private func build(line li: Int) -> ParagraphDecoration {
        let pr = lines.paragraphRange(ofLine: li)
        let cr = lines.contentRange(ofLine: li)
        var d = ParagraphDecoration()
        if hiddenLines.contains(li) {
            d.role = .hidden
            d.alwaysConceal = [cr]
            return d
        }
        d.lineHeightMultiple = theme.lineHeightMultiple
        d.styles = [StyleRun(pr, .font(theme.bodyFont)), StyleRun(pr, .foreground(theme.textColor))]

        let path = document.path(containing: pr.location)
        guard !path.isEmpty else {
            // Blank line hugging a heading, table or block quote: draw it compact (unless the
            // caret is on it), so the customary empty lines around them don't read as double
            // spacing.
            if isBlank(cr), hugsCompactNeighbor(li - 1) || hugsCompactNeighbor(li + 1) {
                d.concealedStyles.append(StyleRun(pr, .font(.systemFont(ofSize: theme.bodySize * 0.4))))
            }
            return d
        }

        var quoteDepth = 0
        var listDepth = 0
        /// Display-only indent of the innermost list item this line belongs to, and the
        /// column its wrapped text hangs at.
        var nestingIndent: CGFloat = 0
        var contentColumns = 0

        for (i, block) in path.enumerated() {
            switch block.kind {
            case .blockQuote:
                quoteDepth += 1
                if quoteDepth == 1 {
                    d.quoteTop = li == lines.line(containing: block.range.location)
                    d.quoteBottom = li == lines.line(containing: max(block.range.location, block.range.end - 1))
                }
                for m in block.markerRanges where cr.contains(m.location) {
                    d.conceal.append(m)
                    d.markerStyles.append(StyleRun(m, .foreground(theme.markerColor)))
                }
            case .listItem(let marker, _, let task):
                listDepth += 1
                // Step each level by a full `listIndentColumns` on screen, whatever the
                // source indents by: two spaces per level is easy to miss when reading.
                let markerColumn = displayColumn(of: marker.location)
                nestingIndent = max(0, CGFloat(listDepth - 1) * theme.listIndentColumns - CGFloat(markerColumn)) * spaceWidth
                contentColumns = markerColumn + (contentStart(after: marker) - marker.location)
                if i + 1 < path.count, case .list = path[i + 1].kind {
                    d.listGuides.append(nestingIndent + CGFloat(quoteDepth) * theme.quoteIndent
                                        + CGFloat(markerColumn) * spaceWidth + markerWidth(marker, task: task) / 2)
                }
                if block.range.location == pr.location {
                    d.listItem = block
                    let isBullet = marker.length == 1
                    if let t = task {
                        // Task items show only the checkbox: hide the bullet and its space
                        d.conceal.append(NSRange(marker.location, to: t.range.location))
                    } else if isBullet {
                        // Solid circle, scaled down and centred: bolder than "•" at body size
                        // without changing the line's height.
                        d.substitutions.append((marker.location, 0x25CF))  // ●
                        d.concealedStyles.append(StyleRun(marker, .font(.systemFont(ofSize: theme.bodySize * 0.55))))
                        d.concealedStyles.append(StyleRun(marker, .baselineOffset(theme.bodySize * 0.14)))
                    }
                    d.styles.append(StyleRun(marker, .foreground(theme.listMarkerColor)))
                    // A list marker is syntax, so on the caret's line it tints like every
                    // other revealed marker — the bullet (rendered as ● or a checkbox) and
                    // the `1.` of an ordered item alike.
                    d.markerStyles.append(StyleRun(marker, .foreground(theme.markerColor)))
                    if let t = task {
                        d.substitutions.append((t.range.location, t.state == .checked ? 0x2611 : 0x2610)) // ☑ ☐
                        d.conceal.append(NSRange(location: t.range.location + 1, length: 2))
                        d.styles.append(StyleRun(t.range, .foreground(t.state == .checked ? theme.accentColor : theme.secondaryColor)))
                        d.task = (t.range, t.state == .checked)
                        if t.state == .checked, let para = block.children.first, case .paragraph = para.kind {
                            d.styles.append(StyleRun(NSRange(location: t.range.end, length: max(0, cr.end - t.range.end)), .foreground(theme.secondaryColor)))
                        }
                    }
                }
            default:
                break
            }
        }

        d.quoteDepth = quoteDepth
        d.headIndent = CGFloat(contentColumns) * spaceWidth + CGFloat(quoteDepth) * theme.quoteIndent + nestingIndent
        d.firstLineHeadIndent = CGFloat(quoteDepth) * theme.quoteIndent + nestingIndent

        guard let leaf = path.last, !leaf.isContainer else { return d }
        leafStyles(leaf, line: li, pr: pr, cr: cr, into: &d)
        return d
    }

    /// Visible column of `offset` on its own line. Block-quote markers are concealed and
    /// stand in as the quote's indent, so they take up no column.
    private func displayColumn(of offset: Int) -> Int {
        let start = lines.lineStarts[lines.line(containing: offset)]
        var column = offset - start
        for block in document.path(containing: offset) {
            guard case .blockQuote = block.kind else { continue }
            for m in block.markerRanges where m.location >= start && m.end <= offset { column -= m.length }
        }
        return max(0, column)
    }

    /// Where a list item's content starts: past its marker and the spaces after it.
    private func contentStart(after marker: NSRange) -> Int {
        let s = document.sourceString as NSString
        let lineEnd = lines.contentRange(ofLine: lines.line(containing: marker.location)).end
        var p = marker.end
        while p < lineEnd, C.isSpaceOrTab(s.character(at: p)) { p += 1 }
        return p
    }

    /// Width of a list item's marker as it renders: ●, a checkbox, or the number as typed.
    private func markerWidth(_ marker: NSRange, task: TaskMarker?) -> CGFloat {
        let s = document.sourceString as NSString
        if let t = task {
            let box: NSString = t.state == .checked ? "☑" : "☐"
            return box.size(withAttributes: [.font: theme.bodyFont]).width
        }
        if marker.length == 1 {
            return ("●" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: theme.bodySize * 0.55)]).width
        }
        return (s.substring(with: marker) as NSString).size(withAttributes: [.font: theme.bodyFont]).width
    }

    private func isBlank(_ r: NSRange) -> Bool {
        guard r.length > 0 else { return true }
        let s = document.sourceString as NSString
        for i in r.location..<r.end where !C.isSpaceOrTab(s.character(at: i)) { return false }
        return true
    }

    /// Does `line` belong to a block whose surrounding blank lines are drawn compact:
    /// a heading (ATX line, or setext text/underline), a table, or a block quote?
    private func hugsCompactNeighbor(_ line: Int) -> Bool {
        guard line >= 0, line < lines.lineCount else { return false }
        let path = document.path(containing: lines.lineStarts[line])
        guard let b = path.last else { return false }
        if path.contains(where: { if case .blockQuote = $0.kind { return true } else { return false } }) { return true }
        switch b.kind { case .heading, .setextHeading, .table: return true; default: return false }
    }

    private func leafStyles(_ leaf: Block, line li: Int, pr: NSRange, cr: NSRange, into d: inout ParagraphDecoration) {
        let firstLine = lines.line(containing: leaf.range.location)
        let lastLine = lines.line(containing: max(leaf.range.location, leaf.range.end - 1))

        switch leaf.kind {
        case .paragraph:
            inlineStyles(leaf, cr: cr, into: &d)

        case .heading(let level):
            d.role = .heading(level)
            d.styles.append(StyleRun(pr, .font(theme.headingFont(level))))
            d.styles.append(StyleRun(pr, .foreground(theme.headingColor)))
            d.spacingBefore = level <= 2 ? theme.bodySize * 0.6 : theme.bodySize * 0.3
            for m in leaf.markerRanges where cr.contains(m.location) {
                d.conceal.append(m)
                d.markerStyles.append(StyleRun(m, .foreground(theme.markerColor)))
            }
            inlineStyles(leaf, cr: cr, into: &d)

        case .setextHeading(let level, let underline):
            if cr.contains(underline.location) {
                d.role = .setextUnderline
                d.conceal.append(underline)
                d.markerStyles.append(StyleRun(underline, .foreground(theme.markerColor)))
            } else {
                d.styles.append(StyleRun(pr, .font(theme.headingFont(level))))
                d.styles.append(StyleRun(pr, .foreground(theme.headingColor)))
                if li == firstLine { d.spacingBefore = theme.bodySize * 0.6 }
                inlineStyles(leaf, cr: cr, into: &d)
            }

        case .thematicBreak:
            d.role = .thematicBreak
            d.conceal.append(cr)
            d.markerStyles.append(StyleRun(cr, .foreground(theme.markerColor)))

        case .fencedCode(let openFence, let closeFence, let info):
            d.styles.append(StyleRun(pr, .font(theme.monoFont)))
            d.lineHeightMultiple = 1.2
            let isOpen = cr.contains(openFence.location) || (openFence.length == 0 && cr.location == openFence.location)
            if let source = diagramSource(leaf, info: info) {
                if isOpen {
                    d.role = .diagramFence(info: info)
                    d.markerStyles.append(StyleRun(openFence, .foreground(theme.markerColor)))
                    diagramFence(source, line: cr, fence: openFence, into: &d)
                } else {
                    let closing = closeFence.map { cr.contains($0.location) || ($0.length == 0 && cr.location == $0.location) } ?? false
                    d.role = .diagramSource(closing: closing)
                    d.conceal.append(cr)
                    if closing, let close = closeFence { d.markerStyles.append(StyleRun(close, .foreground(theme.markerColor))) }
                }
            } else if cr.contains(openFence.location) || (openFence.length == 0 && cr.location == openFence.location) {
                d.role = .fenceOpen(info: info)
                d.conceal.append(openFence)
                d.markerStyles.append(StyleRun(openFence, .foreground(theme.markerColor)))
            } else if let close = closeFence, cr.contains(close.location) || (close.length == 0 && cr.location == close.location) {
                d.role = .fenceClose
                d.conceal.append(close)
                d.markerStyles.append(StyleRun(close, .foreground(theme.markerColor)))
            } else {
                let firstContent = firstLine + 1
                let lastContent = closeFence == nil ? lastLine : lastLine - 1
                d.role = .codeLine(info: info, first: li == firstContent, last: li == lastContent)
                for (r, token) in highlightTokens(for: leaf, info: info) where NSIntersectionRange(r, cr).length > 0 {
                    d.styles.append(StyleRun(r, .foreground(theme.color(for: token))))
                }
            }

        case .indentedCode:
            d.styles.append(StyleRun(pr, .font(theme.monoFont)))
            d.lineHeightMultiple = 1.2
            d.role = .indentedCode(first: li == firstLine, last: li == lastLine)

        case .htmlBlock:
            d.role = .html
            d.styles.append(StyleRun(pr, .font(theme.monoFont)))
            d.styles.append(StyleRun(pr, .foreground(theme.secondaryColor)))

        case .table(let table):
            tableRow(table, block: leaf, line: li, pr: pr, cr: cr, into: &d)

        case .frontmatter:
            d.role = .frontmatter(first: li == firstLine, last: li == lastLine)
            d.styles.append(StyleRun(pr, .font(theme.smallMonoFont)))
            d.styles.append(StyleRun(pr, .foreground(theme.secondaryColor)))
            d.lineHeightMultiple = 1.2
            for m in leaf.markerRanges where cr.contains(m.location) {
                d.styles.append(StyleRun(m, .foreground(theme.markerColor)))
            }

        case .linkReferenceDefinition:
            d.styles.append(StyleRun(pr, .font(theme.smallMonoFont)))
            d.styles.append(StyleRun(pr, .foreground(theme.secondaryColor)))

        case .footnoteDefinition:
            d.styles.append(StyleRun(pr, .font(.systemFont(ofSize: theme.bodySize * 0.85))))
            d.styles.append(StyleRun(pr, .foreground(theme.secondaryColor)))
            if li == firstLine, let m = leaf.markerRanges.first {
                // `[^label]:` → show the label as a superscript, hide the brackets and colon
                let labelRange = NSRange(location: m.location + 2, length: max(0, m.length - 4))
                d.conceal.append(NSRange(location: m.location, length: 2))
                let tail = NSRange(labelRange.end, to: m.end)
                if tail.length > 0 { d.conceal.append(tail) }
                d.markerStyles.append(StyleRun(m, .foreground(theme.markerColor)))
                superscript(labelRange, into: &d)
            }
            inlineStyles(leaf, cr: cr, into: &d)

        case .blockQuote, .list, .listItem:
            break
        }
    }

    private func inlineStyles(_ block: Block, cr: NSRange, into d: inout ParagraphDecoration) {
        inlineStyles(block.inlines, cr: cr, into: &d)
    }

    private func inlineStyles(_ inlines: [Inline], cr: NSRange, into d: inout ParagraphDecoration) {
        func walk(_ nodes: [Inline]) {
            for n in nodes {
                guard NSIntersectionRange(n.range, cr).length > 0 else { continue }
                let r = n.range
                switch n.kind {
                case .strong:
                    d.styles.append(StyleRun(r, .traits(.bold)))
                case .emphasis:
                    d.styles.append(StyleRun(r, .traits(.italic)))
                case .strikethrough:
                    d.styles.append(StyleRun(r, .strikethrough))
                case .code:
                    d.styles.append(StyleRun(r, .mono))
                    d.styles.append(StyleRun(r, .background(theme.codeBackground)))
                case .link(let dest, let title):
                    if let url = Self.linkURL(dest, baseURL: baseURL) { d.styles.append(StyleRun(r, .link(url))) }
                    d.styles.append(StyleRun(r, .foreground(theme.accentColor)))
                    d.styles.append(StyleRun(r, .toolTip(title.map { "\($0) — \(dest)" } ?? dest)))
                case .autolink(let dest):
                    if let url = Self.linkURL(dest, baseURL: baseURL) { d.styles.append(StyleRun(r, .link(url))) }
                    d.styles.append(StyleRun(r, .foreground(theme.accentColor)))
                    d.styles.append(StyleRun(r, .toolTip(dest)))
                case .image(let dest, let alt):
                    d.styles.append(StyleRun(r, .foreground(theme.secondaryColor)))
                    d.styles.append(StyleRun(r, .toolTip(alt.isEmpty ? dest : "\(alt) — \(dest)")))
                    imageInline(r, destination: dest, alt: alt, cr: cr, into: &d)
                case .html:
                    d.styles.append(StyleRun(r, .mono))
                    d.styles.append(StyleRun(r, .foreground(theme.secondaryColor)))
                case .footnoteReference:
                    superscript(NSRange(location: r.location + 2, length: max(0, r.length - 3)), into: &d)
                case .text, .softBreak, .hardBreak, .escape:
                    break
                }
                for m in n.markerRanges where NSIntersectionRange(m, cr).length > 0 {
                    // An image's `!` is the attachment character while concealed; it must
                    // keep a real font, so the conceal range starts after it.
                    if case .image = n.kind, m.location == r.location, d.substitutions.contains(where: { $0.offset == r.location }) {
                        if m.length > 1 { d.conceal.append(NSRange(location: m.location + 1, length: m.length - 1)) }
                    } else {
                        d.conceal.append(m)
                    }
                    d.markerStyles.append(StyleRun(m, .foreground(theme.markerColor)))
                }
                walk(n.children)
            }
        }
        walk(inlines)
    }

    // MARK: - Code highlighting

    /// Tokens for a fenced block's content lines, computed once per block.
    private func highlightTokens(for block: Block, info: String) -> [(NSRange, CodeToken)] {
        if let hit = codeTokens[block.range.location] { return hit }
        guard let highlighter = Highlighters.highlighter(for: info), let first = block.contentRanges.first, let last = block.contentRanges.last else {
            codeTokens[block.range.location] = []
            return []
        }
        // Content lines are contiguous in the source (fence indent stripping aside), so
        // tokenize the span once and offset the results.
        let span = NSRange(first.location, to: last.end)
        let code = (document.sourceString as NSString).substring(with: span)
        let tokens = highlighter.tokens(in: code).map { (NSRange(location: $0.0.location + span.location, length: $0.0.length), $0.1) }
        codeTokens[block.range.location] = tokens
        return tokens
    }

    // MARK: - Tables

    /// Column rule positions (relative to the paragraph's left edge) for the table
    /// containing `offset`, or nil.
    public func tableBoundaries(at offset: Int) -> [CGFloat]? {
        guard let block = document.path(containing: offset).last, case .table(let t) = block.kind else { return nil }
        return tableLayout(for: t, blockStart: block.range.location).boundaries
    }

    struct TableLayout {
        var columnWidths: [CGFloat]
        /// Column rule positions relative to the paragraph's left edge; `count == columns + 1`.
        var boundaries: [CGFloat]
        /// Rendered width of each cell, `[row][cell]`, matching `Table.allRows`.
        var cellWidths: [[CGFloat]]
    }

    /// Column widths from the widest rendered cell in each column. Markers are concealed
    /// except in the revealed cell, which is measured as the user sees it.
    private func tableLayout(for table: Table, blockStart: Int) -> TableLayout {
        if let hit = tableLayouts[blockStart] { return hit }
        let columns = table.allRows.map(\.cells.count).max() ?? 0
        var widths = [CGFloat](repeating: 24, count: columns)
        var cellWidths: [[CGFloat]] = []
        for (ri, row) in table.allRows.enumerated() {
            var rowWidths: [CGFloat] = []
            for (ci, cell) in row.cells.enumerated() {
                let revealed = revealedCell.map { $0.blockStart == blockStart && $0.rowIndex == ri && $0.cellIndex == ci } ?? false
                let w = ceil(measure(cell, header: ri == 0, markersVisible: revealed))
                rowWidths.append(w)
                if ci < columns { widths[ci] = max(widths[ci], w) }
            }
            cellWidths.append(rowWidths)
        }
        var boundaries: [CGFloat] = [0]
        for w in widths { boundaries.append(boundaries.last! + w + 2 * Self.cellGutter) }
        let layout = TableLayout(columnWidths: widths, boundaries: boundaries, cellWidths: cellWidths)
        tableLayouts[blockStart] = layout
        return layout
    }

    /// Rendered width of a cell with its inline styles applied.
    private func measure(_ cell: TableCell, header: Bool, markersVisible: Bool) -> CGFloat {
        guard cell.range.length > 0 else { return 0 }
        let source = (document.sourceString as NSString).substring(with: cell.range)
        let out = NSMutableAttributedString(string: source, attributes: [.font: header ? theme.bodyFont.adding(.bold) : theme.bodyFont])
        var d = ParagraphDecoration()
        inlineStyles(cell.inlines, cr: cell.range, into: &d)
        for run in d.styles { MarkdownContentStorageDelegate.apply(run, to: out, base: cell.range) }
        if !markersVisible {
            for (offset, ch) in d.substitutions {
                let i = offset - cell.range.location
                guard i >= 0, i < out.length else { continue }
                let attrs = out.attributes(at: i, effectiveRange: nil)
                out.replaceCharacters(in: NSRange(location: i, length: 1), with: NSAttributedString(string: String(utf16CodeUnits: [ch], count: 1), attributes: attrs))
            }
            for run in d.concealedStyles { MarkdownContentStorageDelegate.apply(run, to: out, base: cell.range) }
            for r in d.conceal {
                if let rel = MarkdownContentStorageDelegate.relative(r, base: cell.range) {
                    out.addAttributes([.font: Theme.concealedFont], range: rel)
                }
            }
        }
        return out.size().width
    }

    private func tableRow(_ table: Table, block: Block, line li: Int, pr: NSRange, cr: NSRange, into d: inout ParagraphDecoration) {
        d.lineHeightMultiple = 1.25
        d.lineBreakMode = .byClipping
        // Delimiter row: structure only, hidden.
        if cr.location == table.delimiterRow.location {
            d.role = .tableDelimiter
            d.alwaysConceal.append(cr)
            return
        }
        let rows = table.allRows
        guard let rowIndex = rows.firstIndex(where: { $0.range.location == cr.location }) else { return }
        let row = rows[rowIndex]
        let isHeader = rowIndex == 0
        let layout = tableLayout(for: table, blockStart: block.range.location)
        let gutter = Self.cellGutter
        d.role = .tableRow(boundaries: layout.boundaries, header: isHeader, first: isHeader, last: rowIndex == rows.count - 1)
        d.cellRanges = row.cells.map(\.range)

        // Cell text: bold header, inline styles, markers concealable per cell.
        for cell in row.cells {
            if isHeader { d.styles.append(StyleRun(cell.range, .traits(.bold))) }
            inlineStyles(cell.inlines, cr: cell.range, into: &d)
        }

        // Padding per cell from its alignment.
        func padding(_ ci: Int) -> (before: CGFloat, after: CGFloat) {
            guard ci < row.cells.count, ci < layout.columnWidths.count else { return (0, 0) }
            let extra = max(0, layout.columnWidths[ci] - layout.cellWidths[rowIndex][ci])
            let align = ci < table.alignments.count ? table.alignments[ci] : .none
            switch align {
            case .right: return (extra, 0)
            case .center: return (floor(extra / 2), extra - floor(extra / 2))
            default: return (0, extra)
            }
        }

        // Separators never reveal. Two roles inside each:
        //  • the *last* character stays at body size but transparent, so a row made only of
        //    structure (a freshly inserted empty row) keeps a full line height and a
        //    full-size caret instead of collapsing to the concealed font's height;
        //  • the *first* character carries the column padding as kern (minus the anchor's
        //    own width). TextKit draws kern correctly but reports the position of the glyph
        //    right after a kerned glyph half a kern short; putting the kern on the first
        //    separator character keeps that mis-metric off the cell text and the caret.
        let source = document.sourceString as NSString
        for (i, sep) in row.separators.enumerated() {
            let isTrailing = i == row.separators.count - 1
            var kern: CGFloat = 0
            if i > 0 { kern += padding(i - 1).after + gutter }
            if i < row.cells.count { kern += gutter + padding(i).before }
            if sep.length == 0 {
                if i == 0 && !isTrailing {
                    d.firstLineHeadIndent += kern   // no leading pipe: pad with the indent instead
                    d.headIndent += kern
                }
                continue
            }
            let anchor = NSRange(location: sep.end - 1, length: 1)
            let first = NSRange(location: sep.location, length: 1)
            if sep.length > 1 { d.alwaysConceal.append(NSRange(sep.location, to: anchor.location)) }
            let anchorWidth = (source.substring(with: anchor) as NSString).size(withAttributes: [.font: theme.bodyFont]).width
            d.styles.append(StyleRun(anchor, .font(theme.bodyFont)))
            d.styles.append(StyleRun(anchor, .foreground(.clear)))
            if !isTrailing {
                d.styles.append(StyleRun(first, .kern(max(0, kern - anchorWidth))))
            }
        }
    }

    private func superscript(_ r: NSRange, into d: inout ParagraphDecoration) {
        guard r.length > 0 else { return }
        d.styles.append(StyleRun(r, .font(.systemFont(ofSize: theme.bodySize * 0.65, weight: .medium))))
        d.styles.append(StyleRun(r, .baselineOffset(theme.bodySize * 0.35)))
        d.styles.append(StyleRun(r, .foreground(theme.accentColor)))
    }

    static func url(_ s: String) -> URL? {
        if let u = URL(string: s), u.scheme != nil { return u }
        if let enc = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let u = URL(string: enc), u.scheme != nil { return u }
        return nil
    }

    /// Schemes a link may carry (PRD §7.1); any other scheme is inert, plain text.
    public static let followedSchemes: Set<String> = ["http", "https", "mailto", "file"]

    /// The URL a link destination names. A destination with a followed scheme stands
    /// alone; a path resolves against the document's directory like an image's, keeping
    /// its `#fragment`; a bare `#fragment` is an anchor into this document (a URL with
    /// no scheme and only a fragment). Nil for a path in an untitled document and for
    /// schemes the editor does not follow.
    public static func linkURL(_ destination: String, baseURL: URL?) -> URL? {
        let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return nil }
        if let u = url(dest), !isPathLike(u) {
            guard followedSchemes.contains(u.scheme?.lowercased() ?? "") else { return nil }
            return u.isFileURL ? withFragment(u.standardizedFileURL, u.fragment) : u
        }
        var path = Substring(dest), fragment: String?
        if let hash = dest.firstIndex(of: "#") {
            path = dest[..<hash]
            fragment = String(dest[dest.index(after: hash)...])
        }
        if path.isEmpty {
            guard let fragment, !fragment.isEmpty else { return nil }
            var c = URLComponents(); c.fragment = fragment
            return c.url
        }
        guard let file = ImageLoader.resolve(String(path), baseURL: baseURL) else { return nil }
        return withFragment(file, fragment)
    }

    /// `standardizedFileURL` drops a fragment; this puts it back.
    private static func withFragment(_ u: URL, _ fragment: String?) -> URL {
        guard let fragment, !fragment.isEmpty, var c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return u }
        c.fragment = fragment
        return c.url ?? u
    }

    /// `C:\notes.md` parses as a URL with scheme `c`; a one-letter scheme is a drive
    /// letter, not a protocol (mirrors `ImageLoader.resolve`).
    private static func isPathLike(_ u: URL) -> Bool { (u.scheme?.count ?? 0) <= 1 }
}

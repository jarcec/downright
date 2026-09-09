import AppKit
import MarkdownKit

/// Maps a parsed `Document` to per-line `ParagraphDecoration`s. Immutable per document
/// version; the controller replaces it after every reparse, which also drops the cache.
@MainActor
public final class DecorationEngine {
    public let document: Document
    public let lines: LineIndex
    public let theme: Theme
    private var cache: [Int: ParagraphDecoration] = [:]
    private var tableLayouts: [Int: TableLayout] = [:]
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
    static let cellGutter: CGFloat = 10

    public init(document: Document, lines: LineIndex, theme: Theme) {
        self.document = document
        self.lines = lines
        self.theme = theme
        self.spaceWidth = theme.spaceWidth
    }

    public func decoration(forParagraphAt location: Int) -> ParagraphDecoration {
        let li = lines.line(containing: location)
        let key = lines.lineStarts[li]
        if let hit = cache[key] { return hit }
        let d = build(line: li)
        cache[key] = d
        return d
    }

    // MARK: - Build

    private func build(line li: Int) -> ParagraphDecoration {
        let pr = lines.paragraphRange(ofLine: li)
        let cr = lines.contentRange(ofLine: li)
        var d = ParagraphDecoration()
        d.lineHeightMultiple = theme.lineHeightMultiple
        d.styles = [StyleRun(pr, .font(theme.bodyFont)), StyleRun(pr, .foreground(theme.textColor))]

        let path = document.path(containing: pr.location)
        guard !path.isEmpty else { return d }

        var indentColumns = 0
        var quoteDepth = 0

        for block in path {
            switch block.kind {
            case .blockQuote:
                quoteDepth += 1
                for m in block.markerRanges where cr.contains(m.location) {
                    d.conceal.append(m)
                    d.markerStyles.append(StyleRun(m, .foreground(theme.markerColor)))
                }
            case .listItem(let marker, let contentIndent, let task):
                indentColumns += contentIndent
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
        d.headIndent = CGFloat(indentColumns) * spaceWidth + CGFloat(quoteDepth) * theme.quoteIndent
        d.firstLineHeadIndent = CGFloat(quoteDepth) * theme.quoteIndent

        guard let leaf = path.last, !leaf.isContainer else { return d }
        leafStyles(leaf, line: li, pr: pr, cr: cr, into: &d)
        return d
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
            if cr.contains(openFence.location) || (openFence.length == 0 && cr.location == openFence.location) {
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
                case .link(let dest, _):
                    if let url = Self.url(dest) { d.styles.append(StyleRun(r, .link(url))) }
                    d.styles.append(StyleRun(r, .foreground(theme.accentColor)))
                case .autolink(let dest):
                    if let url = Self.url(dest) { d.styles.append(StyleRun(r, .link(url))) }
                    d.styles.append(StyleRun(r, .foreground(theme.accentColor)))
                case .image:
                    d.styles.append(StyleRun(r, .foreground(theme.secondaryColor)))
                case .html:
                    d.styles.append(StyleRun(r, .mono))
                    d.styles.append(StyleRun(r, .foreground(theme.secondaryColor)))
                case .text, .softBreak, .hardBreak, .escape:
                    break
                }
                for m in n.markerRanges where NSIntersectionRange(m, cr).length > 0 {
                    d.conceal.append(m)
                    d.markerStyles.append(StyleRun(m, .foreground(theme.markerColor)))
                }
                walk(n.children)
            }
        }
        walk(inlines)
    }

    // MARK: - Tables

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

        // Separators never reveal; the last character of each carries the column padding.
        for (i, sep) in row.separators.enumerated() {
            if sep.length > 0 { d.alwaysConceal.append(sep) }
            var kern: CGFloat = 0
            if i > 0 { kern += padding(i - 1).after + gutter }
            if i < row.cells.count { kern += gutter + padding(i).before }
            if i == row.separators.count - 1 { continue }   // trailing: nothing follows
            if sep.length > 0 {
                d.styles.append(StyleRun(NSRange(location: sep.end - 1, length: 1), .kern(kern)))
            } else if i == 0 {
                d.firstLineHeadIndent += kern   // no leading pipe: pad with the indent instead
                d.headIndent += kern
            }
        }
    }

    static func url(_ s: String) -> URL? {
        if let u = URL(string: s), u.scheme != nil { return u }
        if let enc = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let u = URL(string: enc), u.scheme != nil { return u }
        return nil
    }
}

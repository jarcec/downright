import Foundation

/// Line-oriented CommonMark block parser with GFM extensions. Whole-document, every
/// call (plan decision D2: this naive parser is the oracle the incremental one will be
/// verified against).
///
/// The algorithm follows cmark's structure. For each line: (1) try to continue the open
/// containers; (2) look for new block starts; (3) add the remainder to a leaf, as a
/// (possibly lazy) paragraph continuation or a new paragraph.
final class BlockParser {
    private let buf: [UInt16]
    private let lines: LineIndex
    private let dialect: Dialect
    private let root: Node
    private var references: [String: String] = [:]
    private var parents: [ObjectIdentifier: Node] = [:]

    /// Mutable node used during parsing; converted to `Block` values at the end.
    final class Node {
        var kind: Block.Kind
        let start: Int
        var end: Int
        var markers: [NSRange] = []
        var contents: [NSRange] = []
        var children: [Node] = []
        var open = true

        var rawLines: [NSRange] = []          // paragraph/heading/table content before finalisation
        // List / list item
        var contentIndent = 0
        var endsWithBlank = false
        var hasInternalBlank = false
        var firstLineBlank = false
        var listDelimiter: UInt16 = 0
        var loose = false
        // Fenced code
        var fenceChar: UInt16 = 0
        var fenceLength = 0
        var fenceIndent = 0
        // HTML block
        var htmlEnd: HTMLEnd = .blankLine
        // Link reference definitions peeled off a paragraph at finalisation
        var lrdSplit: [Node] = []

        init(kind: Block.Kind, start: Int) {
            self.kind = kind
            self.start = start
            self.end = start
        }

        var isContainer: Bool {
            switch kind {
            case .blockQuote, .list, .listItem: return true
            default: return false
            }
        }
        var isParagraph: Bool { if case .paragraph = kind { return true }; return false }
        var lastOpenChild: Node? {
            guard let last = children.last, last.open else { return nil }
            return last
        }
    }

    enum HTMLEnd { case blankLine, contains(String), containsAny([String]) }

    init(source buf: [UInt16], dialect: Dialect, references: [String: String] = [:]) {
        self.buf = buf
        self.lines = LineIndex(utf16: buf)
        self.dialect = dialect
        self.root = Node(kind: .paragraph, start: 0) // kind unused for root
        self.references = references
    }

    var lineIndex: LineIndex { lines }

    // MARK: - Entry

    func parse() -> Document {
        var lineIndex = 0
        if dialect.frontmatter, let fm = parseFrontmatter() {
            root.children.append(fm.node)
            lineIndex = fm.nextLine
        }
        let (blocks, _, _) = parseLines(from: lineIndex, stop: nil)
        return Document(blocks: blocks, length: buf.count, references: references, sourceString: String(utf16CodeUnits: buf, count: buf.count))
    }

    /// Parse from `fromLine` until the end or until, at a clean top-level boundary (no open
    /// blocks) beyond the first line, `stop(offset)` returns true. Used by incremental
    /// reparsing. Returns the blocks, the references found, and the offset stopped at.
    func parseLines(from fromLine: Int, stop: ((Int) -> Bool)?) -> (blocks: [Block], references: [String: String], stoppedAt: Int?) {
        let before = references
        var li = fromLine
        var stoppedAt: Int? = nil
        while li < lines.lineCount {
            // Skip the phantom empty line after a trailing newline
            if li == lines.lineCount - 1 && lines.lineStarts[li] == buf.count && buf.count > 0 { break }
            if let stop, li > fromLine, root.lastOpenChild == nil, stop(lines.lineStarts[li]) {
                stoppedAt = lines.lineStarts[li]
                break
            }
            processLine(li)
            li += 1
        }
        closeAll(root)
        let blocks = root.children.flatMap { convert($0) }
        var found: [String: String] = [:]
        for (k, v) in references where before[k] != v { found[k] = v }
        return (blocks, found, stoppedAt)
    }

    // MARK: - Frontmatter

    private func parseFrontmatter() -> (node: Node, nextLine: Int)? {
        guard lines.lineCount > 1 else { return nil }
        let first = lines.contentRange(ofLine: 0)
        guard isExactly(first, "---") else { return nil }
        for i in 1..<lines.lineCount {
            let r = lines.contentRange(ofLine: i)
            if isExactly(r, "---") || isExactly(r, "...") {
                let node = Node(kind: .frontmatter, start: 0)
                node.end = lines.paragraphRange(ofLine: i).end
                node.markers = [first, r]
                for j in 1..<i { node.contents.append(lines.contentRange(ofLine: j)) }
                node.open = false
                return (node, i + 1)
            }
        }
        return nil
    }

    private func isExactly(_ r: NSRange, _ s: String) -> Bool {
        var end = r.end
        while end > r.location && C.isSpaceOrTab(buf[end - 1]) { end -= 1 }
        let u = Array(s.utf16)
        guard end - r.location == u.count else { return false }
        for (k, c) in u.enumerated() where buf[r.location + k] != c { return false }
        return true
    }

    // MARK: - Per-line

    private func processLine(_ li: Int) {
        let lineStart = lines.lineStarts[li]
        let lineEnd = lines.contentRange(ofLine: li).end
        let lineEndIncl = lines.paragraphRange(ofLine: li).end
        var pos = lineStart

        // ── Phase 1: continue open containers ─────────────────────────────────────
        var container = root
        var allMatched = true
        descend: while let child = container.lastOpenChild, child.isContainer {
            switch child.kind {
            case .blockQuote:
                let (indent, after) = indentation(from: pos, upTo: lineEnd)
                if indent <= 3 && after < lineEnd && buf[after] == C.gt {
                    var p = after + 1
                    if p < lineEnd && C.isSpaceOrTab(buf[p]) { p += 1 }
                    child.markers.append(NSRange(after, to: p))
                    pos = p
                    container = child
                } else {
                    allMatched = false; break descend
                }
            case .list:
                guard let item = child.lastOpenChild, let p = matchListItem(item, from: pos, to: lineEnd) else {
                    allMatched = false; break descend
                }
                pos = p
                container = item
            case .listItem:
                guard let p = matchListItem(child, from: pos, to: lineEnd) else { allMatched = false; break descend }
                pos = p
                container = child
            default:
                break descend
            }
        }

        let blankAfterContainers = isBlank(from: pos, to: lineEnd)

        // ── Verbatim leaves swallow the whole line when their containers matched ──
        if allMatched, let leaf = container.lastOpenChild, !leaf.isContainer {
            switch leaf.kind {
            case .fencedCode(let openFence, _, let info):
                if isClosingFence(leaf, from: pos, to: lineEnd) {
                    let closeRange = NSRange(pos, to: lineEnd)
                    leaf.markers.append(closeRange)
                    leaf.kind = .fencedCode(openFence: openFence, closeFence: closeRange, info: info)
                    extendEnds(leaf, to: lineEndIncl)
                    leaf.open = false
                } else {
                    let p = advance(from: pos, columns: leaf.fenceIndent, upTo: lineEnd)
                    leaf.contents.append(NSRange(p, to: lineEnd))
                    extendEnds(leaf, to: lineEndIncl)
                }
                return
            case .htmlBlock:
                if blankAfterContainers, case .blankLine = leaf.htmlEnd {
                    leaf.open = false
                    break   // fall through to normal blank handling
                }
                leaf.contents.append(NSRange(pos, to: lineEnd))
                extendEnds(leaf, to: lineEndIncl)
                if htmlEndReached(leaf, line: NSRange(pos, to: lineEnd)) { leaf.open = false }
                return
            case .indentedCode:
                let (indent, _) = indentation(from: pos, upTo: lineEnd)
                if blankAfterContainers {
                    leaf.contents.append(NSRange(min(advance(from: pos, columns: 4, upTo: lineEnd), lineEnd), to: lineEnd))
                    return
                } else if indent >= 4 {
                    let p = advance(from: pos, columns: 4, upTo: lineEnd)
                    leaf.contents.append(NSRange(p, to: lineEnd))
                    extendEnds(leaf, to: lineEndIncl)
                    return
                }
                close(leaf)
            case .table:
                if !blankAfterContainers && !startsNewBlock(from: pos, to: lineEnd) {
                    leaf.rawLines.append(NSRange(pos, to: lineEnd))
                    extendEnds(leaf, to: lineEndIncl)
                    return
                }
                close(leaf)
            default:
                break
            }
        }

        // ── Phase 2: new block starts ─────────────────────────────────────────────
        var startedNew = false
        let tipParagraph = deepestOpenLeaf(from: container).flatMap { $0.isParagraph ? $0 : nil }

        scan: while true {
            let (indent, after) = indentation(from: pos, upTo: lineEnd)
            if after >= lineEnd { break scan }      // blank (or nothing but whitespace)
            if indent >= 4 {
                if tipParagraph != nil && !startedNew { break scan }   // paragraph continuation, not code
                closeOpenChild(container)
                let node = Node(kind: .indentedCode, start: lineStart)
                node.contents.append(NSRange(advance(from: pos, columns: 4, upTo: lineEnd), to: lineEnd))
                addChild(node, to: container)
                extendEnds(node, to: lineEndIncl)
                return
            }
            let c = buf[after]

            if c == C.gt {
                closeOpenChild(container)
                let node = Node(kind: .blockQuote, start: lineStart)
                var p = after + 1
                if p < lineEnd && C.isSpaceOrTab(buf[p]) { p += 1 }
                node.markers.append(NSRange(after, to: p))
                addChild(node, to: container)
                extendEnds(node, to: lineEndIncl)
                container = node; pos = p; startedNew = true
                continue scan
            }
            if c == C.hash, let h = atxHeading(from: after, to: lineEnd) {
                closeOpenChild(container)
                let node = Node(kind: .heading(level: h.level), start: lineStart)
                node.markers = h.markers
                node.rawLines = [h.content]
                addChild(node, to: container)
                extendEnds(node, to: lineEndIncl)
                close(node)
                return
            }
            if (c == C.backtick || c == C.tilde), let f = fenceOpen(from: after, to: lineEnd, indent: indent) {
                closeOpenChild(container)
                let fenceLine = NSRange(pos, to: lineEnd)
                let node = Node(kind: .fencedCode(openFence: fenceLine, closeFence: nil, info: f.info), start: lineStart)
                node.fenceChar = f.char; node.fenceLength = f.length; node.fenceIndent = indent
                node.markers.append(fenceLine)
                addChild(node, to: container)
                extendEnds(node, to: lineEndIncl)
                return
            }
            if c == C.lt, let html = htmlBlockStart(from: after, to: lineEnd, inParagraph: tipParagraph != nil && allMatched && !startedNew) {
                closeOpenChild(container)
                let node = Node(kind: .htmlBlock, start: lineStart)
                node.htmlEnd = html
                node.contents.append(NSRange(pos, to: lineEnd))
                addChild(node, to: container)
                extendEnds(node, to: lineEndIncl)
                if case .blankLine = html {} else if htmlEndReached(node, line: NSRange(pos, to: lineEnd)) { node.open = false }
                return
            }
            if allMatched, !startedNew, let para = container.lastOpenChild, para.isParagraph,
               let level = setextUnderline(from: after, to: lineEnd) {
                let underline = NSRange(pos, to: lineEnd)
                para.kind = .setextHeading(level: level, underline: underline)
                para.markers.append(underline)
                extendEnds(para, to: lineEndIncl)
                close(para)
                return
            }
            if isThematicBreak(from: after, to: lineEnd) {
                closeOpenChild(container)
                let node = Node(kind: .thematicBreak, start: lineStart)
                node.markers.append(NSRange(pos, to: lineEnd))
                addChild(node, to: container)
                extendEnds(node, to: lineEndIncl)
                close(node)
                return
            }
            if let item = listItemStart(from: after, to: lineEnd, indent: indent) {
                if tipParagraph != nil && allMatched && !startedNew {
                    // A list item can interrupt a paragraph only if non-empty and (if ordered) starting at 1
                    if item.isEmpty || (item.ordered && item.start != 1) { break scan }
                }
                let list: Node
                if let last = container.lastOpenChild, case .list(let ordered, _, _) = last.kind,
                   ordered == item.ordered, last.listDelimiter == item.delimiter {
                    // Sibling item of an existing list: close the previous item, keep the list
                    if let prev = last.lastOpenChild {
                        if prev.endsWithBlank { last.loose = true }
                        close(prev)
                    }
                    list = last
                } else {
                    closeOpenChild(container)
                    list = Node(kind: .list(ordered: item.ordered, tight: true, start: item.start), start: lineStart)
                    list.listDelimiter = item.delimiter
                    addChild(list, to: container)
                }
                let node = Node(kind: .listItem(marker: item.marker, contentIndent: item.contentIndent, task: item.task), start: lineStart)
                node.contentIndent = item.contentIndent
                node.markers.append(item.marker)
                if let t = item.task { node.markers.append(t.range) }
                node.firstLineBlank = item.isEmpty
                addChild(node, to: list)
                extendEnds(node, to: lineEndIncl)
                container = node; pos = item.contentStart; startedNew = true
                continue scan
            }
            break scan
        }

        // ── Phase 3: text ─────────────────────────────────────────────────────────
        let blank = isBlank(from: pos, to: lineEnd)

        if !blank, !startedNew, let para = tipParagraph {
            // Paragraph continuation — lazy if containers did not all match
            let (_, after) = indentation(from: pos, upTo: lineEnd)
            if dialect.tables, allMatched, para.rawLines.count == 1,
               isTableDelimiterRow(NSRange(after, to: lineEnd), headerCells: cellCount(para.rawLines[0])) {
                para.kind = .table(Table(header: TableRow(range: para.rawLines[0], cells: [], separators: []),
                                        delimiterRow: NSRange(after, to: lineEnd), alignments: [], rows: []))
                para.rawLines.append(NSRange(after, to: lineEnd))
                extendEnds(para, to: lineEndIncl)
                return
            }
            para.rawLines.append(NSRange(after, to: lineEnd))
            extendEnds(para, to: lineEndIncl)
            return
        }

        // Not a lazy continuation: everything below the last matched container closes
        closeOpenChild(container)

        if blank {
            markBlank(container)
            return
        }

        let (_, after) = indentation(from: pos, upTo: lineEnd)
        let node = Node(kind: .paragraph, start: lineStart)
        node.rawLines.append(NSRange(after, to: lineEnd))
        addChild(node, to: container)
        extendEnds(node, to: lineEndIncl)
    }

    /// Returns the position after the item's content indent if the line continues `item`.
    private func matchListItem(_ item: Node, from pos: Int, to lineEnd: Int) -> Int? {
        if isBlank(from: pos, to: lineEnd) {
            // An item may begin with at most one blank line
            if item.firstLineBlank && item.children.isEmpty { return nil }
            return pos
        }
        let (indent, _) = indentation(from: pos, upTo: lineEnd)
        guard indent >= item.contentIndent else { return nil }
        return advance(from: pos, columns: item.contentIndent, upTo: lineEnd)
    }

    private func deepestOpenLeaf(from container: Node) -> Node? {
        var n = container
        while let child = n.lastOpenChild { n = child }
        return (n !== container || !container.isContainer) && !n.isContainer && n !== root ? n : nil
    }

    // MARK: - Tree maintenance

    private func addChild(_ node: Node, to parent: Node) {
        parent.children.append(node)
        parents[ObjectIdentifier(node)] = parent
        // List looseness bookkeeping: content after a blank line inside an item
        if case .listItem = parent.kind, parent.endsWithBlank, parent.children.count > 1 {
            parent.hasInternalBlank = true
        }
        var n: Node? = parent
        while let cur = n, cur !== root {
            if case .listItem = cur.kind { cur.endsWithBlank = false }
            n = parents[ObjectIdentifier(cur)]
        }
    }

    private func extendEnds(_ node: Node, to end: Int) {
        var n: Node? = node
        while let cur = n {
            if cur.end < end { cur.end = end }
            n = parents[ObjectIdentifier(cur)]
        }
    }

    private func markBlank(_ container: Node) {
        var n: Node? = container
        while let cur = n, cur !== root {
            if case .listItem = cur.kind, !cur.children.isEmpty || cur.firstLineBlank { cur.endsWithBlank = true }
            n = parents[ObjectIdentifier(cur)]
        }
    }

    private func closeOpenChild(_ container: Node) {
        if let child = container.lastOpenChild { close(child) }
    }

    private func closeAll(_ node: Node) {
        for child in node.children where child.open { close(child) }
    }

    private func close(_ node: Node) {
        guard node.open else { return }
        for child in node.children where child.open { close(child) }
        node.open = false
        switch node.kind {
        case .paragraph:
            finalizeParagraph(node)
        case .heading, .setextHeading:
            node.contents = trimTrailingSpaces(node.rawLines)
        case .table(let partial):
            node.contents = node.rawLines
            node.kind = .table(buildTable(from: node.rawLines, delimiterRow: partial.delimiterRow))
        case .indentedCode:
            while let last = node.contents.last, isBlank(from: last.location, to: last.end) {
                node.contents.removeLast()
            }
        case .list(let ordered, _, let start):
            var tight = !node.loose
            for item in node.children where item.hasInternalBlank { tight = false }
            node.kind = .list(ordered: ordered, tight: tight, start: start)
            if let last = node.children.last { node.end = last.end }
        case .listItem, .blockQuote:
            if let last = node.children.last { node.end = max(node.end, last.end) }
        default:
            break
        }
    }

    private func trimTrailingSpaces(_ ranges: [NSRange]) -> [NSRange] {
        ranges.map { r in
            var end = r.end
            while end > r.location && C.isSpaceOrTab(buf[end - 1]) { end -= 1 }
            return NSRange(r.location, to: end)
        }
    }

    private func finalizeParagraph(_ node: Node) {
        var linesLeft = node.rawLines
        var lrds: [Node] = []
        while let first = linesLeft.first, let (label, dest) = linkReferenceDefinition(first) {
            references[label] = dest
            let li = lines.line(containing: first.location)
            let lrd = Node(kind: .linkReferenceDefinition, start: lines.lineStarts[li])
            lrd.end = lines.paragraphRange(ofLine: li).end
            lrd.contents = [first]
            lrd.open = false
            lrds.append(lrd)
            linesLeft.removeFirst()
        }
        if lrds.isEmpty {
            node.contents = trimLastLine(node.rawLines)
            return
        }
        node.lrdSplit = lrds
        if linesLeft.isEmpty {
            node.kind = .linkReferenceDefinition
            node.contents = []
        } else {
            node.contents = trimLastLine(linesLeft)
        }
    }

    /// Paragraph lines keep trailing spaces (they may be hard breaks) except the last.
    private func trimLastLine(_ ranges: [NSRange]) -> [NSRange] {
        guard let last = ranges.last else { return ranges }
        return Array(ranges.dropLast()) + trimTrailingSpaces([last])
    }

    // MARK: - Conversion

    private func convert(_ node: Node) -> [Block] {
        var out: [Block] = []
        for lrd in node.lrdSplit {
            out.append(Block(kind: .linkReferenceDefinition, range: NSRange(lrd.start, to: lrd.end), contentRanges: lrd.contents))
        }
        if case .linkReferenceDefinition = node.kind, !node.lrdSplit.isEmpty { return out }

        var start = node.start
        if !node.lrdSplit.isEmpty, let first = node.contents.first {
            start = lines.lineStarts[lines.line(containing: first.location)]
        }
        var block = Block(kind: node.kind, range: NSRange(start, to: node.end),
                          markerRanges: node.markers, contentRanges: node.contents)
        block.children = node.children.flatMap { convert($0) }
        switch node.kind {
        case .paragraph, .heading, .setextHeading:
            block.inlines = InlineParser(source: buf, contentRanges: node.contents, dialect: dialect,
                                         references: references).parse()
        case .table(var table):
            func parsed(_ row: TableRow) -> TableRow {
                var r = row
                r.cells = row.cells.map { cell in
                    TableCell(range: cell.range, inlines: InlineParser(source: buf, contentRanges: [cell.range], dialect: dialect, references: references).parse())
                }
                return r
            }
            table.header = parsed(table.header)
            table.rows = table.rows.map(parsed)
            block.kind = .table(table)
        default:
            break
        }
        out.append(block)
        return out
    }

    // MARK: - Scanning helpers

    /// Leading indentation in columns from `pos` (tab advances to the next multiple of 4).
    private func indentation(from pos: Int, upTo end: Int) -> (columns: Int, after: Int) {
        var p = pos, col = 0
        while p < end {
            if buf[p] == C.space { col += 1 }
            else if buf[p] == C.tab { col += 4 - (col % 4) }
            else { break }
            p += 1
        }
        return (col, p)
    }

    /// Consume up to `columns` columns of whitespace.
    private func advance(from pos: Int, columns: Int, upTo end: Int) -> Int {
        var p = pos, col = 0
        while p < end && col < columns {
            if buf[p] == C.space { col += 1 }
            else if buf[p] == C.tab { col += 4 - (col % 4) }
            else { break }
            p += 1
        }
        return p
    }

    private func isBlank(from pos: Int, to end: Int) -> Bool {
        var p = pos
        while p < end { if !C.isSpaceOrTab(buf[p]) { return false }; p += 1 }
        return true
    }

    private func startsNewBlock(from pos: Int, to end: Int) -> Bool {
        let (indent, after) = indentation(from: pos, upTo: end)
        guard indent <= 3, after < end else { return false }
        let c = buf[after]
        if c == C.gt { return true }
        if c == C.hash && atxHeading(from: after, to: end) != nil { return true }
        if (c == C.backtick || c == C.tilde) && fenceOpen(from: after, to: end, indent: indent) != nil { return true }
        if isThematicBreak(from: after, to: end) { return true }
        if listItemStart(from: after, to: end, indent: indent) != nil { return true }
        return false
    }

    private struct ATX { var level: Int; var markers: [NSRange]; var content: NSRange }

    private func atxHeading(from p: Int, to end: Int) -> ATX? {
        var q = p
        while q < end && buf[q] == C.hash { q += 1 }
        let level = q - p
        guard level >= 1 && level <= 6 else { return nil }
        guard q == end || C.isSpaceOrTab(buf[q]) else { return nil }
        var contentStart = q
        while contentStart < end && C.isSpaceOrTab(buf[contentStart]) { contentStart += 1 }
        var markers = [NSRange(p, to: contentStart)]
        var contentEnd = end
        while contentEnd > contentStart && C.isSpaceOrTab(buf[contentEnd - 1]) { contentEnd -= 1 }
        var k = contentEnd
        while k > contentStart && buf[k - 1] == C.hash { k -= 1 }
        if k < contentEnd && (k == contentStart || C.isSpaceOrTab(buf[k - 1])) {
            var m = k
            while m > contentStart && C.isSpaceOrTab(buf[m - 1]) { m -= 1 }
            markers.append(NSRange(m, to: end))
            contentEnd = m
        } else if contentEnd < end {
            markers.append(NSRange(contentEnd, to: end))
        }
        return ATX(level: level, markers: markers, content: NSRange(contentStart, to: contentEnd))
    }

    private struct Fence { var char: UInt16; var length: Int; var info: String }

    private func fenceOpen(from p: Int, to end: Int, indent: Int) -> Fence? {
        guard indent <= 3 else { return nil }
        let ch = buf[p]
        var q = p
        while q < end && buf[q] == ch { q += 1 }
        let len = q - p
        guard len >= 3 else { return nil }
        let rest = NSRange(q, to: end)
        if ch == C.backtick {
            for i in rest.location..<rest.end where buf[i] == C.backtick { return nil }
        }
        let info = buf.string(rest).trimmingCharacters(in: .whitespaces)
        return Fence(char: ch, length: len, info: info)
    }

    private func isClosingFence(_ leaf: Node, from pos: Int, to end: Int) -> Bool {
        let (indent, after) = indentation(from: pos, upTo: end)
        guard indent <= 3, after < end, buf[after] == leaf.fenceChar else { return false }
        var q = after
        while q < end && buf[q] == leaf.fenceChar { q += 1 }
        guard q - after >= leaf.fenceLength else { return false }
        return isBlank(from: q, to: end)
    }

    private func setextUnderline(from p: Int, to end: Int) -> Int? {
        guard p < end else { return nil }
        let ch = buf[p]
        guard ch == C.eq || ch == C.minus else { return nil }
        var q = p
        while q < end && buf[q] == ch { q += 1 }
        guard isBlank(from: q, to: end) else { return nil }
        return ch == C.eq ? 1 : 2
    }

    private func isThematicBreak(from p: Int, to end: Int) -> Bool {
        guard p < end else { return false }
        let ch = buf[p]
        guard ch == C.minus || ch == C.star || ch == C.underscore else { return false }
        var count = 0, q = p
        while q < end {
            if buf[q] == ch { count += 1 }
            else if !C.isSpaceOrTab(buf[q]) { return false }
            q += 1
        }
        return count >= 3
    }

    private struct ListItemStart {
        var ordered: Bool
        var start: Int
        var delimiter: UInt16
        var marker: NSRange
        var contentIndent: Int
        var contentStart: Int
        var isEmpty: Bool
        var task: TaskMarker?
    }

    private func listItemStart(from p: Int, to end: Int, indent: Int) -> ListItemStart? {
        guard indent <= 3, p < end else { return nil }
        var q = p
        var ordered = false
        var start = 1
        let c = buf[p]
        if c == C.minus || c == C.plus || c == C.star {
            q = p + 1
        } else if C.isDigit(c) {
            var n = 0, digits = 0
            while q < end && C.isDigit(buf[q]) && digits < 10 { n = n * 10 + Int(buf[q] - 48); q += 1; digits += 1 }
            guard digits <= 9, q < end, buf[q] == C.dot || buf[q] == C.rparen else { return nil }
            q += 1
            ordered = true
            start = n
        } else {
            return nil
        }
        guard q == end || C.isSpaceOrTab(buf[q]) else { return nil }
        let marker = NSRange(p, to: q)
        let markerWidth = q - p
        let (spaces, afterSpaces) = indentation(from: q, upTo: end)
        let isEmpty = afterSpaces >= end
        var contentIndent: Int
        var contentStart: Int
        if isEmpty || spaces >= 5 {
            contentIndent = indent + markerWidth + 1
            contentStart = min(q + 1, end)
        } else {
            contentIndent = indent + markerWidth + spaces
            contentStart = afterSpaces
        }
        var task: TaskMarker? = nil
        if dialect.taskLists, !isEmpty, contentStart + 2 < end,
           buf[contentStart] == C.lbracket, buf[contentStart + 2] == C.rbracket,
           contentStart + 3 == end || C.isSpaceOrTab(buf[contentStart + 3]) {
            let m = buf[contentStart + 1]
            if m == C.space || m == C.x || m == C.X {
                task = TaskMarker(state: m == C.space ? .unchecked : .checked, range: NSRange(location: contentStart, length: 3))
                var cs = contentStart + 3
                if cs < end && C.isSpaceOrTab(buf[cs]) { cs += 1 }
                contentStart = cs
            }
        }
        return ListItemStart(ordered: ordered, start: start, delimiter: ordered ? buf[q - 1] : c, marker: marker,
                             contentIndent: contentIndent, contentStart: contentStart, isEmpty: isEmpty, task: task)
    }

    // MARK: HTML blocks

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
        "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
        "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
        "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
        "th", "thead", "title", "tr", "track", "ul",
    ]

    private func htmlBlockStart(from p: Int, to end: Int, inParagraph: Bool) -> HTMLEnd? {
        let line = buf.string(NSRange(p, to: end))
        let lower = line.lowercased()
        if lower.hasPrefix("<!--") { return .contains("-->") }
        if lower.hasPrefix("<?") { return .contains("?>") }
        if lower.hasPrefix("<![cdata[") { return .contains("]]>") }
        if lower.hasPrefix("<!"), lower.count > 2, lower[lower.index(lower.startIndex, offsetBy: 2)].isLetter { return .contains(">") }
        for t in ["script", "pre", "style", "textarea"] where lower.hasPrefix("<" + t) {
            let after = lower.dropFirst(t.count + 1)
            if after.isEmpty || after.first == " " || after.first == ">" || after.first == "\t" {
                return .containsAny(["</" + t + ">"])
            }
        }
        var rest = Substring(lower.dropFirst())
        if rest.hasPrefix("/") { rest = rest.dropFirst() }
        let name = rest.prefix { $0.isLetter || $0.isNumber }
        if !name.isEmpty && Self.blockTags.contains(String(name)) {
            let after = rest.dropFirst(name.count)
            if after.isEmpty || after.first == " " || after.first == "\t" || after.first == ">" || after.hasPrefix("/>") {
                return .blankLine
            }
        }
        if !inParagraph, Self.isCompleteTagLine(line) { return .blankLine }
        return nil
    }

    private static func isCompleteTagLine(_ s: String) -> Bool {
        guard s.hasPrefix("<"), let gt = s.firstIndex(of: ">") else { return false }
        let tail = s[s.index(after: gt)...]
        guard tail.allSatisfy({ $0 == " " || $0 == "\t" }) else { return false }
        var inner = s[s.index(after: s.startIndex)..<gt]
        if inner.hasPrefix("/") { inner = inner.dropFirst() }
        guard let first = inner.first, first.isLetter else { return false }
        return !inner.contains("<")
    }

    private func htmlEndReached(_ node: Node, line: NSRange) -> Bool {
        switch node.htmlEnd {
        case .blankLine: return false
        case .contains(let s): return buf.string(line).contains(s)
        case .containsAny(let ss):
            let l = buf.string(line).lowercased()
            return ss.contains { l.contains($0) }
        }
    }

    // MARK: Tables

    /// Split a row into trimmed cells and the separator runs between them.
    func splitRow(_ r: NSRange) -> TableRow {
        var pipes: [Int] = []
        var p = r.location
        while p < r.end {
            if buf[p] == C.backslash { p += 2; continue }
            if buf[p] == C.pipe { pipes.append(p) }
            p += 1
        }
        // Content boundaries: start after a leading pipe, end before a trailing pipe.
        var start = r.location, end = r.end
        while start < end && C.isSpaceOrTab(buf[start]) { start += 1 }
        while end > start && C.isSpaceOrTab(buf[end - 1]) { end -= 1 }
        var inner = pipes
        var hasLeading = false, hasTrailing = false
        if let f = inner.first, f == start { hasLeading = true; inner.removeFirst() }
        if let l = inner.last, l == end - 1, end - 1 >= start, !(hasLeading && pipes.count == 1) { hasTrailing = true; inner.removeLast() }
        // Cell raw spans between the boundaries/pipes
        var bounds: [(Int, Int)] = []
        var cursor = hasLeading ? start + 1 : start
        for pipe in inner { bounds.append((cursor, pipe)); cursor = pipe + 1 }
        bounds.append((cursor, hasTrailing ? end - 1 : end))
        var cells: [TableCell] = []
        var separators: [NSRange] = []
        var prevContentEnd = r.location
        for (a, b) in bounds {
            var cs = a, ce = b
            while cs < ce && C.isSpaceOrTab(buf[cs]) { cs += 1 }
            while ce > cs && C.isSpaceOrTab(buf[ce - 1]) { ce -= 1 }
            separators.append(NSRange(prevContentEnd, to: cs))
            cells.append(TableCell(range: NSRange(cs, to: ce)))
            prevContentEnd = ce
        }
        separators.append(NSRange(prevContentEnd, to: r.end))
        return TableRow(range: r, cells: cells, separators: separators)
    }

    private func buildTable(from lines: [NSRange], delimiterRow: NSRange) -> Table {
        let header = splitRow(lines[0])
        let delimiterCells = splitRow(delimiterRow).cells
        var alignments: [TableAlignment] = delimiterCells.map { cell in
            let t = buf.string(cell.range)
            let l = t.hasPrefix(":"), r = t.hasSuffix(":")
            switch (l, r) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            default: return .none
            }
        }
        while alignments.count < header.cells.count { alignments.append(.none) }
        let rows = lines.dropFirst(2).map { splitRow($0) }
        return Table(header: header, delimiterRow: delimiterRow, alignments: alignments, rows: Array(rows))
    }

    private func cellCount(_ r: NSRange) -> Int {
        var start = r.location, end = r.end
        while start < end && C.isSpaceOrTab(buf[start]) { start += 1 }
        while end > start && C.isSpaceOrTab(buf[end - 1]) { end -= 1 }
        if start < end && buf[start] == C.pipe { start += 1 }
        if end > start && buf[end - 1] == C.pipe && (end - 2 < start || buf[end - 2] != C.backslash) { end -= 1 }
        var count = 1, p = start
        while p < end {
            if buf[p] == C.backslash { p += 2; continue }
            if buf[p] == C.pipe { count += 1 }
            p += 1
        }
        return count
    }

    private func isTableDelimiterRow(_ r: NSRange, headerCells: Int) -> Bool {
        var start = r.location, end = r.end
        while start < end && C.isSpaceOrTab(buf[start]) { start += 1 }
        while end > start && C.isSpaceOrTab(buf[end - 1]) { end -= 1 }
        guard start < end else { return false }
        var hasPipe = false
        for i in start..<end where buf[i] == C.pipe { hasPipe = true; break }
        if buf[start] == C.pipe { start += 1 }
        if end > start && buf[end - 1] == C.pipe { end -= 1 }
        let cells = buf.string(NSRange(start, to: end)).split(separator: "|", omittingEmptySubsequences: false)
        guard cells.count == headerCells, hasPipe || cells.count > 1 else { return false }
        for cell in cells {
            let t = cell.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return false }
            var body = Substring(t)
            if body.hasPrefix(":") { body = body.dropFirst() }
            if body.hasSuffix(":") { body = body.dropLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return false }
        }
        return true
    }

    // MARK: Link reference definitions

    /// Lower-cased label and destination if the line is a complete single-line definition.
    private func linkReferenceDefinition(_ r: NSRange) -> (String, String)? {
        var p = r.location
        let end = r.end
        guard p < end, buf[p] == C.lbracket else { return nil }
        p += 1
        let labelStart = p
        while p < end && buf[p] != C.rbracket {
            if buf[p] == C.backslash { p += 1 }
            else if buf[p] == C.lbracket { return nil }
            p += 1
        }
        guard p < end, p > labelStart else { return nil }
        let label = buf.string(NSRange(labelStart, to: p)).trimmingCharacters(in: .whitespaces).lowercased()
        guard !label.isEmpty else { return nil }
        p += 1
        guard p < end, buf[p] == C.colon else { return nil }
        p += 1
        while p < end && C.isSpaceOrTab(buf[p]) { p += 1 }
        guard p < end else { return nil }
        let dest: String
        if buf[p] == C.lt {
            let ds = p + 1
            while p < end && buf[p] != C.gt { p += 1 }
            guard p < end else { return nil }
            dest = buf.string(NSRange(ds, to: p))
            p += 1
        } else {
            let ds = p
            while p < end && !C.isSpaceOrTab(buf[p]) { p += 1 }
            guard p > ds else { return nil }
            dest = buf.string(NSRange(ds, to: p))
        }
        while p < end && C.isSpaceOrTab(buf[p]) { p += 1 }
        if p < end {
            let open = buf[p]
            let close: UInt16 = open == C.dquote ? C.dquote : open == C.squote ? C.squote : open == C.lparen ? C.rparen : 0
            guard close != 0 else { return nil }
            p += 1
            while p < end && buf[p] != close { if buf[p] == C.backslash { p += 1 }; p += 1 }
            guard p < end else { return nil }
            p += 1
            while p < end && C.isSpaceOrTab(buf[p]) { p += 1 }
            guard p == end else { return nil }
        }
        return (label, dest)
    }
}

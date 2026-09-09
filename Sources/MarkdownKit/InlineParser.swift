import Foundation

/// CommonMark inline parser (delimiter-run algorithm) with GFM strikethrough and bare
/// autolinks. Runs over a leaf block's content lines, which are copied into a scratch
/// buffer with a map back to source offsets so every node reports absolute ranges.
struct InlineParser {
    private let buf: [UInt16]        // scratch
    private let map: [Int]           // scratch index → source index
    private let sourceEnd: Int
    private let dialect: Dialect
    private let references: [String: String]

    init(source: [UInt16], contentRanges: [NSRange], dialect: Dialect, references: [String: String]) {
        var scratch: [UInt16] = []
        var map: [Int] = []
        var total = 0
        for r in contentRanges { total += r.length + 1 }
        scratch.reserveCapacity(total)
        map.reserveCapacity(total)
        for (i, r) in contentRanges.enumerated() {
            if i > 0 {
                scratch.append(C.newline)
                map.append(contentRanges[i - 1].end)
            }
            if r.length > 0 {
                scratch.append(contentsOf: source[r.location..<r.end])
                for k in r.location..<r.end { map.append(k) }
            }
        }
        self.buf = scratch
        self.map = map
        self.sourceEnd = contentRanges.last?.end ?? 0
        self.dialect = dialect
        self.references = references
    }

    // MARK: - Working node

    final class INode {
        var kind: Inline.Kind
        var start: Int
        var end: Int
        var markers: [NSRange] = []
        var children: [INode] = []
        // delimiter run state
        var isDelim = false
        var delimChar: UInt16 = 0
        var count = 0
        var origCount = 0
        var canOpen = false
        var canClose = false
        // bracket state
        var isBracket = false
        var isImage = false
        var active = true

        init(_ kind: Inline.Kind, _ start: Int, _ end: Int) {
            self.kind = kind; self.start = start; self.end = end
        }
    }

    // MARK: - Entry

    func parse() -> [Inline] {
        guard !buf.isEmpty else { return [] }
        var nodes: [INode] = []
        var brackets: [INode] = []
        let n = buf.count
        var pos = 0
        var textStart = 0

        func flushText(to end: Int) {
            if end > textStart { nodes.append(INode(.text, textStart, end)) }
        }

        while pos < n {
            let c = buf[pos]
            switch c {
            case C.backslash:
                if pos + 1 < n, C.isAsciiPunct(buf[pos + 1]) {
                    flushText(to: pos)
                    let node = INode(.escape, pos, pos + 2)
                    node.markers = [NSRange(location: pos, length: 1)]
                    nodes.append(node)
                    pos += 2; textStart = pos
                } else if pos + 1 < n, buf[pos + 1] == C.newline {
                    flushText(to: pos)
                    let node = INode(.hardBreak, pos, pos + 2)
                    node.markers = [NSRange(location: pos, length: 1)]
                    nodes.append(node)
                    pos += 2; textStart = pos
                } else {
                    pos += 1
                }

            case C.backtick:
                var q = pos
                while q < n && buf[q] == C.backtick { q += 1 }
                let k = q - pos
                if let close = findBacktickClose(from: q, length: k) {
                    flushText(to: pos)
                    let node = INode(.code, pos, close + k)
                    node.markers = [NSRange(location: pos, length: k), NSRange(location: close, length: k)]
                    nodes.append(node)
                    pos = close + k; textStart = pos
                } else {
                    pos = q
                }

            case C.lt:
                if let (dest, end) = autolink(at: pos) {
                    flushText(to: pos)
                    let node = INode(.autolink(destination: dest), pos, end)
                    node.markers = [NSRange(location: pos, length: 1), NSRange(location: end - 1, length: 1)]
                    nodes.append(node)
                    pos = end; textStart = pos
                } else if let end = inlineHTML(at: pos) {
                    flushText(to: pos)
                    nodes.append(INode(.html, pos, end))
                    pos = end; textStart = pos
                } else {
                    pos += 1
                }

            case C.star, C.underscore:
                var q = pos
                while q < n && buf[q] == c { q += 1 }
                flushText(to: pos)
                let node = delimiterNode(char: c, start: pos, end: q)
                nodes.append(node)
                pos = q; textStart = pos

            case C.tilde where dialect.strikethrough:
                var q = pos
                while q < n && buf[q] == C.tilde { q += 1 }
                if q - pos <= 2 {
                    flushText(to: pos)
                    nodes.append(delimiterNode(char: c, start: pos, end: q))
                    pos = q; textStart = pos
                } else {
                    pos = q
                }

            case C.lbracket:
                flushText(to: pos)
                let node = INode(.text, pos, pos + 1)
                node.isBracket = true
                nodes.append(node); brackets.append(node)
                pos += 1; textStart = pos

            case C.bang where pos + 1 < n && buf[pos + 1] == C.lbracket:
                flushText(to: pos)
                let node = INode(.text, pos, pos + 2)
                node.isBracket = true; node.isImage = true
                nodes.append(node); brackets.append(node)
                pos += 2; textStart = pos

            case C.rbracket:
                flushText(to: pos)
                textStart = pos
                guard let opener = brackets.last else { pos += 1; continue }
                if !opener.active {
                    brackets.removeLast(); opener.isBracket = false
                    pos += 1; continue
                }
                if let (kind, tailEnd) = linkTail(closingAt: pos, opener: opener) {
                    let oi = nodes.lastIndex { $0 === opener }!
                    var inner = Array(nodes[(oi + 1)...])
                    processEmphasis(&inner, from: 0)
                    let link = INode(kind, opener.start, tailEnd)
                    link.markers = [NSRange(opener.start, to: opener.end), NSRange(pos, to: tailEnd)]
                    link.children = inner
                    nodes.replaceSubrange(oi..., with: [link])
                    brackets.removeLast()
                    if !opener.isImage { for b in brackets where !b.isImage { b.active = false } }
                    pos = tailEnd; textStart = pos
                } else {
                    brackets.removeLast(); opener.isBracket = false
                    pos += 1
                }

            case C.newline:
                // Hard break: two or more spaces before the newline
                var s = pos
                while s > textStart && buf[s - 1] == C.space { s -= 1 }
                if pos - s >= 2 {
                    flushText(to: s)
                    let node = INode(.hardBreak, s, pos + 1)
                    node.markers = [NSRange(s, to: pos)]
                    nodes.append(node)
                } else {
                    flushText(to: pos)
                    nodes.append(INode(.softBreak, pos, pos + 1))
                }
                pos += 1; textStart = pos

            default:
                if dialect.bareAutolinks, let (dest, end) = bareAutolink(at: pos) {
                    flushText(to: pos)
                    nodes.append(INode(.autolink(destination: dest), pos, end))
                    pos = end; textStart = pos
                } else {
                    pos += 1
                }
            }
        }
        flushText(to: n)
        processEmphasis(&nodes, from: 0)
        return nodes.map(convert).mergedText()
    }

    // MARK: - Delimiters

    private func delimiterNode(char: UInt16, start: Int, end: Int) -> INode {
        let node = INode(.text, start, end)
        node.isDelim = true
        node.delimChar = char
        node.count = end - start
        node.origCount = node.count
        let before: UInt16 = start == 0 ? C.newline : buf[start - 1]
        let after: UInt16 = end >= buf.count ? C.newline : buf[end]
        let afterWS = C.isWhitespace(after), beforeWS = C.isWhitespace(before)
        let afterP = C.isPunctuation(after), beforeP = C.isPunctuation(before)
        let left = !afterWS && (!afterP || beforeWS || beforeP)
        let right = !beforeWS && (!beforeP || afterWS || afterP)
        if char == C.underscore {
            node.canOpen = left && (!right || beforeP)
            node.canClose = right && (!left || afterP)
        } else {
            node.canOpen = left
            node.canClose = right
        }
        return node
    }

    private func processEmphasis(_ nodes: inout [INode], from startIndex: Int) {
        var i = startIndex
        while i < nodes.count {
            let closer = nodes[i]
            guard closer.isDelim, closer.canClose, closer.count > 0 else { i += 1; continue }
            var j = i - 1
            var found: Int? = nil
            while j >= startIndex {
                let op = nodes[j]
                if op.isDelim, op.delimChar == closer.delimChar, op.canOpen, op.count > 0 {
                    let oddMatch = (op.canClose || closer.canOpen)
                        && closer.origCount % 3 != 0
                        && (op.origCount + closer.origCount) % 3 == 0
                    if closer.delimChar == C.tilde {
                        if op.count == closer.count { found = j; break }
                    } else if !oddMatch {
                        found = j; break
                    }
                }
                j -= 1
            }
            guard let oj = found else {
                if !closer.canOpen { closer.isDelim = false }
                i += 1; continue
            }
            let opener = nodes[oj]
            let use: Int
            let kind: Inline.Kind
            if closer.delimChar == C.tilde {
                use = closer.count; kind = .strikethrough
            } else {
                use = (opener.count >= 2 && closer.count >= 2) ? 2 : 1
                kind = use == 2 ? .strong : .emphasis
            }
            let node = INode(kind, opener.end - use, closer.start + use)
            node.markers = [NSRange(location: opener.end - use, length: use), NSRange(location: closer.start, length: use)]
            node.children = Array(nodes[(oj + 1)..<i])
            opener.count -= use; opener.end -= use
            closer.count -= use; closer.start += use
            nodes.replaceSubrange((oj + 1)..<i, with: [node])
            i = oj + 2
            if opener.count == 0 { nodes.remove(at: oj); i -= 1 }
            if closer.count == 0 { nodes.remove(at: i) }
        }
        for node in nodes where node.isDelim { node.isDelim = false }
    }

    // MARK: - Code spans

    private func findBacktickClose(from start: Int, length k: Int) -> Int? {
        var p = start
        while p < buf.count {
            if buf[p] == C.backtick {
                var q = p
                while q < buf.count && buf[q] == C.backtick { q += 1 }
                if q - p == k { return p }
                p = q
            } else {
                p += 1
            }
        }
        return nil
    }

    // MARK: - Links

    private func linkTail(closingAt pos: Int, opener: INode) -> (Inline.Kind, Int)? {
        let n = buf.count
        let textRange = NSRange(opener.end, to: pos)
        func make(_ dest: String, _ title: String?) -> Inline.Kind {
            opener.isImage ? .image(destination: dest, alt: plainText(textRange)) : .link(destination: dest, title: title)
        }
        if pos + 1 < n, buf[pos + 1] == C.lparen {
            if let (dest, title, end) = inlineLinkTail(from: pos + 1) { return (make(dest, title), end) }
            // fall through to reference forms
        }
        if pos + 1 < n, buf[pos + 1] == C.lbracket {
            var q = pos + 2
            while q < n && buf[q] != C.rbracket && buf[q] != C.lbracket { if buf[q] == C.backslash { q += 1 }; q += 1 }
            guard q < n, buf[q] == C.rbracket else { return nil }
            let label = normalizeLabel(NSRange(pos + 2, to: q))
            if label.isEmpty {   // collapsed [text][]
                let l = normalizeLabel(textRange)
                if let dest = references[l] { return (make(dest, nil), q + 1) }
                return nil
            }
            if let dest = references[label] { return (make(dest, nil), q + 1) }
            return nil
        }
        // shortcut [text]
        let l = normalizeLabel(textRange)
        if let dest = references[l] { return (make(dest, nil), pos + 1) }
        return nil
    }

    private func inlineLinkTail(from lp: Int) -> (String, String?, Int)? {
        let n = buf.count
        var p = lp + 1
        while p < n && C.isWhitespace(buf[p]) { p += 1 }
        guard p < n else { return nil }
        var dest = ""
        if buf[p] == C.lt {
            var q = p + 1
            while q < n && buf[q] != C.gt && buf[q] != C.lt && buf[q] != C.newline { if buf[q] == C.backslash { q += 1 }; q += 1 }
            guard q < n, buf[q] == C.gt else { return nil }
            dest = unescape(NSRange(p + 1, to: q))
            p = q + 1
        } else {
            var depth = 0
            let ds = p
            while p < n {
                let c = buf[p]
                if c == C.backslash && p + 1 < n && C.isAsciiPunct(buf[p + 1]) { p += 2; continue }
                if C.isWhitespace(c) || c < 32 { break }
                if c == C.lparen { depth += 1 }
                if c == C.rparen { if depth == 0 { break }; depth -= 1 }
                p += 1
            }
            guard depth == 0 else { return nil }
            dest = unescape(NSRange(ds, to: p))
        }
        var title: String? = nil
        let beforeWS = p
        while p < n && C.isWhitespace(buf[p]) { p += 1 }
        if p < n, p > beforeWS, buf[p] == C.dquote || buf[p] == C.squote || buf[p] == C.lparen {
            let open = buf[p]
            let close: UInt16 = open == C.lparen ? C.rparen : open
            var q = p + 1
            while q < n && buf[q] != close { if buf[q] == C.backslash { q += 1 }; q += 1 }
            guard q < n else { return nil }
            title = unescape(NSRange(p + 1, to: q))
            p = q + 1
            while p < n && C.isWhitespace(buf[p]) { p += 1 }
        }
        guard p < n, buf[p] == C.rparen else { return nil }
        return (dest, title, p + 1)
    }

    private func normalizeLabel(_ r: NSRange) -> String {
        buf.string(r).lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func unescape(_ r: NSRange) -> String {
        var out: [UInt16] = []
        var p = r.location
        while p < r.end {
            if buf[p] == C.backslash && p + 1 < r.end && C.isAsciiPunct(buf[p + 1]) { p += 1 }
            out.append(buf[p]); p += 1
        }
        return String(utf16CodeUnits: out, count: out.count)
    }

    private func plainText(_ r: NSRange) -> String { buf.string(r) }

    // MARK: - Autolinks and HTML

    private func autolink(at pos: Int) -> (String, Int)? {
        let n = buf.count
        var p = pos + 1
        guard p < n, C.isAsciiLetter(buf[p]) else { return nil }
        // scheme
        var q = p
        while q < n && (C.isAlnum(buf[q]) || buf[q] == C.plus || buf[q] == C.dot || buf[q] == C.minus) { q += 1 }
        if q < n, buf[q] == C.colon, q - p >= 2, q - p <= 32 {
            var e = q + 1
            while e < n && buf[e] != C.gt && buf[e] != C.lt && !C.isWhitespace(buf[e]) { e += 1 }
            guard e < n, buf[e] == C.gt else { return nil }
            return (buf.string(NSRange(p, to: e)), e + 1)
        }
        // email
        q = p
        var sawAt = false
        while q < n && buf[q] != C.gt {
            let c = buf[q]
            if c == 64 { if sawAt { return nil }; sawAt = true }
            else if !(C.isAlnum(c) || c == C.dot || c == C.minus || c == C.underscore || c == C.plus || C.isAsciiPunct(c) && c != C.lt && c != C.gt && c != C.space) { return nil }
            if C.isWhitespace(c) || c == C.lt { return nil }
            q += 1
        }
        guard q < n, sawAt, q > p + 2 else { return nil }
        p = pos + 1
        return ("mailto:" + buf.string(NSRange(p, to: q)), q + 1)
    }

    private func inlineHTML(at pos: Int) -> Int? {
        let n = buf.count
        var p = pos + 1
        guard p < n else { return nil }
        if buf[p] == C.bang, p + 2 < n, buf[p + 1] == C.minus, buf[p + 2] == C.minus {
            // comment
            var q = p + 3
            while q + 2 < n {
                if buf[q] == C.minus && buf[q + 1] == C.minus && buf[q + 2] == C.gt { return q + 3 }
                q += 1
            }
            return nil
        }
        if buf[p] == C.slash { p += 1 }
        guard p < n, C.isAsciiLetter(buf[p]) else { return nil }
        while p < n && (C.isAlnum(buf[p]) || buf[p] == C.minus) { p += 1 }
        while p < n && buf[p] != C.gt {
            if buf[p] == C.lt { return nil }
            if buf[p] == C.dquote || buf[p] == C.squote {
                let qch = buf[p]; p += 1
                while p < n && buf[p] != qch { p += 1 }
                guard p < n else { return nil }
            }
            p += 1
        }
        guard p < n else { return nil }
        return p + 1
    }

    private func bareAutolink(at pos: Int) -> (String, Int)? {
        let n = buf.count
        let c = buf[pos]
        guard c == 104 || c == 72 || c == 119 || c == 87 else { return nil } // h H w W
        if pos > 0 {
            let b = buf[pos - 1]
            guard C.isWhitespace(b) || b == C.star || b == C.underscore || b == C.tilde || b == C.lparen else { return nil }
        }
        let lower = { (i: Int) -> UInt16 in let x = buf[i]; return (x >= 65 && x <= 90) ? x + 32 : x }
        func hasPrefix(_ s: String) -> Bool {
            let u = Array(s.utf16)
            guard pos + u.count <= n else { return false }
            for (k, ch) in u.enumerated() where lower(pos + k) != ch { return false }
            return true
        }
        var isWWW = false
        if hasPrefix("http://") || hasPrefix("https://") {} else if hasPrefix("www.") { isWWW = true } else { return nil }
        var e = pos
        while e < n && !C.isWhitespace(buf[e]) && buf[e] != C.lt { e += 1 }
        // trailing punctuation
        while e > pos {
            let t = buf[e - 1]
            if t == C.question || t == C.bang || t == C.dot || t == 44 || t == C.colon || t == C.star || t == C.underscore || t == C.tilde || t == C.dquote || t == C.squote {
                e -= 1
            } else if t == C.rparen {
                var opens = 0, closes = 0
                for i in pos..<e { if buf[i] == C.lparen { opens += 1 } else if buf[i] == C.rparen { closes += 1 } }
                if closes > opens { e -= 1 } else { break }
            } else { break }
        }
        let text = buf.string(NSRange(pos, to: e))
        guard e - pos > (isWWW ? 4 : 8) else { return nil }
        return (isWWW ? "http://" + text : text, e)
    }

    // MARK: - Conversion to source ranges

    private func src(_ r: NSRange) -> NSRange {
        guard r.length > 0 else {
            let loc = r.location < map.count ? map[r.location] : sourceEnd
            return NSRange(location: loc, length: 0)
        }
        return NSRange(map[r.location], to: map[r.end - 1] + 1)
    }

    private func convert(_ node: INode) -> Inline {
        Inline(kind: node.kind,
               range: src(NSRange(node.start, to: node.end)),
               markerRanges: node.markers.map(src),
               children: node.children.map(convert).mergedText())
    }
}

private extension Array where Element == Inline {
    /// Merge runs of adjacent, contiguous text nodes.
    func mergedText() -> [Inline] {
        var out: [Inline] = []
        for node in self {
            if case .text = node.kind, let last = out.last, case .text = last.kind, last.range.end == node.range.location {
                out[out.count - 1].range = NSRange(last.range.location, to: node.range.end)
            } else {
                out.append(node)
            }
        }
        return out
    }
}

import Foundation

/// Words and characters as a reader counts them: the text the document shows, not its
/// syntax. Markers, link destinations, HTML, front matter, reference definitions and
/// the sources of diagrams and formulas are left out; code is text people read, so it
/// stays in.
public struct ProseCounts: Equatable, Sendable {
    public var words: Int
    /// Characters as people see them (grapheme clusters), line breaks not included.
    public var characters: Int
    public init(words: Int, characters: Int) { self.words = words; self.characters = characters }

    /// Minutes to read `words` at an unhurried 230 words a minute, rounded up.
    public static func readingMinutes(words: Int) -> Int { words == 0 ? 0 : max(1, Int((Double(words) / 230).rounded(.up))) }
}

extension Document {
    /// The shown text in pieces. Each inner array is one line of a block; its pieces join
    /// with nothing between them (`foo**bar**` is one word), and lines are separate.
    public func proseRuns() -> [[NSRange]] {
        var out: [[NSRange]] = []
        func inlineLines(_ lines: [NSRange], _ inlines: [Inline]) {
            var cut: [NSRange] = []
            func walk(_ nodes: [Inline]) {
                for n in nodes {
                    switch n.kind {
                    case .html, .image, .footnoteReference: cut.append(n.range); continue
                    default: break
                    }
                    cut.append(contentsOf: n.markerRanges)
                    walk(n.children)
                }
            }
            walk(inlines)
            cut.sort { $0.location < $1.location }
            for line in lines {
                let pieces = Self.subtract(cut, from: line)
                if !pieces.isEmpty { out.append(pieces) }
            }
        }
        func visit(_ blocks: [Block]) {
            for b in blocks {
                switch b.kind {
                case .blockQuote, .list, .listItem:
                    visit(b.children)
                case .paragraph, .heading, .setextHeading, .footnoteDefinition:
                    inlineLines(b.contentRanges, b.inlines)
                case .table(let t):
                    for row in t.allRows {
                        for cell in row.cells { inlineLines([cell.range], cell.inlines) }
                    }
                case .fencedCode(_, _, let info):
                    let lang = info.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first?.lowercased()
                    if lang == "mermaid" || lang == "math" { continue }
                    out.append(contentsOf: b.contentRanges.filter { $0.length > 0 }.map { [$0] })
                case .indentedCode:
                    out.append(contentsOf: b.contentRanges.filter { $0.length > 0 }.map { [$0] })
                case .thematicBreak, .htmlBlock, .frontmatter, .linkReferenceDefinition:
                    continue
                }
            }
        }
        visit(blocks)
        return out
    }

    /// Counts over `runs` (from `proseRuns`), only within `clip` when given.
    public static func counts(of runs: [[NSRange]], in source: NSString, within clip: NSRange? = nil) -> ProseCounts {
        var counter = ProseCounter()
        for run in runs {
            for piece in run {
                let r = clip.map { NSIntersectionRange($0, piece) } ?? piece
                guard r.length > 0 else { continue }
                counter.add(source.substring(with: r))
            }
            counter.endLine()
        }
        return ProseCounts(words: counter.words, characters: counter.characters)
    }

    /// `line` with every range in `cut` (sorted) taken out.
    private static func subtract(_ cut: [NSRange], from line: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        var p = line.location
        for c in cut where c.end > p && c.location < line.end {
            if c.location > p { out.append(NSRange(p, to: c.location)) }
            p = max(p, c.end)
        }
        if p < line.end { out.append(NSRange(p, to: line.end)) }
        return out
    }
}

/// Words are runs of letters and digits, held together by an apostrophe or a hyphen
/// between them (`don't`, `e-mail`). Chinese and Japanese are written without spaces,
/// so each of their characters counts as a word, the way word processors count them.
private struct ProseCounter {
    var words = 0
    var characters = 0
    private var inWord = false

    mutating func add(_ text: String) {
        characters += text.reduce(0) { $1.isNewline ? $0 : $0 + 1 }
        for s in text.unicodeScalars {
            if Self.isIdeograph(s) {
                words += 1
                inWord = false
            } else if CharacterSet.alphanumerics.contains(s) {
                if !inWord { words += 1; inWord = true }
            } else if inWord, s == "'" || s == "\u{2019}" || s == "-" || s == "\u{2010}" {
                continue   // joins only when a letter follows; a stray one ends nothing new
            } else {
                inWord = false
            }
        }
    }

    mutating func endLine() { inWord = false }

    private static func isIdeograph(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }
}

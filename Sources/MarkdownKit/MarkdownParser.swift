import Foundation

public enum MarkdownParser {
    /// Parse a complete document. Whole-document, non-incremental (plan decision D2).
    public static func parse(_ source: String, dialect: Dialect = .gfm) -> Document {
        parse(utf16: Array(source.utf16), dialect: dialect)
    }

    public static func parse(utf16: [UInt16], dialect: Dialect = .gfm) -> Document {
        BlockParser(source: utf16, dialect: dialect).parse()
    }
}

// MARK: - Queries used by the decoration layer

extension Document {
    /// The chain of blocks containing `offset`, outermost first. Empty if `offset` falls
    /// between top-level blocks (a blank line). Containers whose gap between children
    /// contains the offset end the chain.
    public func path(containing offset: Int) -> [Block] {
        var path: [Block] = []
        var level = blocks
        while let b = Self.block(in: level, containing: offset) {
            path.append(b)
            level = b.children
        }
        return path
    }

    private static func block(in blocks: [Block], containing offset: Int) -> Block? {
        var lo = 0, hi = blocks.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = blocks[mid].range
            if offset < r.location { hi = mid - 1 }
            else if offset >= r.end { lo = mid + 1 }
            else { return blocks[mid] }
        }
        return nil
    }

    /// Every inline node (depth-first, parents before children) in `block` that
    /// intersects `range`.
    public static func inlines(in block: Block, intersecting range: NSRange) -> [Inline] {
        var out: [Inline] = []
        func walk(_ nodes: [Inline]) {
            for n in nodes where NSIntersectionRange(n.range, range).length > 0 || (n.range.length == 0 && range.contains(n.range.location)) {
                out.append(n)
                walk(n.children)
            }
        }
        walk(block.inlines)
        return out
    }
}

// MARK: - Debug description

extension Document {
    /// Compact structural dump used by tests: one node per line, indented by depth.
    public func dump(source: String) -> String {
        let buf = Array(source.utf16)
        var out = ""
        func text(_ r: NSRange) -> String {
            buf.string(r).replacingOccurrences(of: "\n", with: "⏎")
        }
        func inl(_ nodes: [Inline], _ depth: Int) {
            for n in nodes {
                out += String(repeating: "  ", count: depth) + "\(n.kind.label) \(n.range.location)..<\(n.range.end)"
                if case .text = n.kind { out += " \"\(text(n.range))\"" }
                if !n.markerRanges.isEmpty { out += " markers=" + n.markerRanges.map { "\($0.location)+\($0.length)" }.joined(separator: ",") }
                out += "\n"
                inl(n.children, depth + 1)
            }
        }
        func blk(_ blocks: [Block], _ depth: Int) {
            for b in blocks {
                out += String(repeating: "  ", count: depth) + "\(b.kind.label) \(b.range.location)..<\(b.range.end)"
                if !b.markerRanges.isEmpty { out += " markers=" + b.markerRanges.map { "\($0.location)+\($0.length)" }.joined(separator: ",") }
                out += "\n"
                inl(b.inlines, depth + 1)
                blk(b.children, depth + 1)
            }
        }
        blk(blocks, 0)
        return out
    }
}

extension Block.Kind {
    public var label: String {
        switch self {
        case .paragraph: return "paragraph"
        case .heading(let l): return "heading\(l)"
        case .setextHeading(let l, _): return "setext\(l)"
        case .thematicBreak: return "hr"
        case .fencedCode(_, let close, let info): return "fence(\(info))" + (close == nil ? "[open]" : "")
        case .indentedCode: return "indented"
        case .htmlBlock: return "html"
        case .blockQuote: return "quote"
        case .list(let o, let t, let s): return "list(\(o ? "ordered@\(s)" : "bullet"),\(t ? "tight" : "loose"))"
        case .listItem(_, let ci, let task): return "item(indent=\(ci)" + (task.map { $0.state == .checked ? ",done" : ",todo" } ?? "") + ")"
        case .table: return "table"
        case .frontmatter: return "frontmatter"
        case .linkReferenceDefinition: return "linkref"
        }
    }
}

extension Inline.Kind {
    public var label: String {
        switch self {
        case .text: return "text"
        case .softBreak: return "softbreak"
        case .hardBreak: return "hardbreak"
        case .escape: return "escape"
        case .code: return "code"
        case .emphasis: return "em"
        case .strong: return "strong"
        case .strikethrough: return "strike"
        case .link(let d, _): return "link(\(d))"
        case .image(let d, _): return "image(\(d))"
        case .autolink(let d): return "autolink(\(d))"
        case .html: return "html"
        }
    }
}

// MARK: - Dialect detection (PRD §8)

/// Which extensions a parsed document actually uses. Detection only ever *widens*
/// the profile; it is descriptive, not a parse setting.
public struct DetectedDialect: Equatable, Sendable {
    public var tables = false
    public var taskLists = false
    public var strikethrough = false
    public var frontmatter = false
    public var bareAutolinks = false

    public var usesExtensions: Bool { tables || taskLists || strikethrough || frontmatter || bareAutolinks }

    /// "CommonMark", or "GFM" followed by the extensions in use.
    public var summary: String {
        guard usesExtensions else { return "CommonMark" }
        var parts: [String] = []
        if frontmatter { parts.append("frontmatter") }
        if tables { parts.append("tables") }
        if taskLists { parts.append("tasks") }
        if strikethrough { parts.append("strikethrough") }
        if bareAutolinks { parts.append("autolinks") }
        return "GFM · " + parts.joined(separator: ", ")
    }

    public static func detect(in document: Document) -> DetectedDialect {
        var d = DetectedDialect()
        func inlines(_ nodes: [Inline]) {
            for n in nodes {
                switch n.kind {
                case .strikethrough: d.strikethrough = true
                case .autolink: if n.markerRanges.isEmpty { d.bareAutolinks = true }
                default: break
                }
                inlines(n.children)
            }
        }
        func blocks(_ list: [Block]) {
            for b in list {
                switch b.kind {
                case .table: d.tables = true
                case .frontmatter: d.frontmatter = true
                case .listItem(_, _, let task): if task != nil { d.taskLists = true }
                default: break
                }
                inlines(b.inlines)
                blocks(b.children)
            }
        }
        blocks(document.blocks)
        return d
    }
}

import Foundation

/// A heading as a link can name it: `#install`, `notes.md#setup-notes`.
public struct HeadingAnchor: Equatable, Sendable {
    public var level: Int
    /// The heading's text as it reads, markers and link destinations left out.
    public var title: String
    /// GitHub's anchor for it, `-1`, `-2` … after the first heading of the same name.
    public var slug: String
    public var offset: Int
}

extension Document {
    /// Every heading's anchor, in document order (headings in quotes and lists too).
    public func headingAnchors() -> [HeadingAnchor] {
        let src = sourceString as NSString
        var out: [HeadingAnchor] = []
        var seen: [String: Int] = [:]
        func walk(_ blocks: [Block]) {
            for b in blocks {
                switch b.kind {
                case .heading(let level), .setextHeading(let level, _):
                    let title = Self.plainText(b.inlines, in: src).trimmingCharacters(in: .whitespaces)
                    let base = Self.slug(title)
                    let n = seen[base, default: 0]
                    seen[base] = n + 1
                    out.append(HeadingAnchor(level: level, title: title, slug: n == 0 ? base : "\(base)-\(n)", offset: b.range.location))
                default:
                    break
                }
                walk(b.children)
            }
        }
        walk(blocks)
        return out
    }

    /// GitHub's heading anchor: lowercased, punctuation dropped, spaces to hyphens.
    public static func slug(_ title: String) -> String {
        var out = ""
        for ch in title.lowercased() {
            if ch == " " || ch == "-" { out.append("-") }
            else if ch.isLetter || ch.isNumber || ch == "_" { out.append(ch) }
        }
        return out
    }

    /// The text inline nodes read as.
    static func plainText(_ nodes: [Inline], in src: NSString) -> String {
        var out = ""
        for n in nodes {
            switch n.kind {
            case .text: out += src.substring(with: n.range)
            case .softBreak, .hardBreak: out += " "
            case .escape: out += src.substring(with: NSRange(location: n.range.location + 1, length: max(0, n.range.length - 1)))
            case .code, .math:
                if n.markerRanges.count == 2 { out += src.substring(with: NSRange(n.markerRanges[0].end, to: n.markerRanges[1].location)).trimmingCharacters(in: .whitespaces) }
            case .autolink(let dest): out += dest
            case .emphasis, .strong, .strikethrough, .link: out += plainText(n.children, in: src)
            case .image, .html, .footnoteReference: break
            }
        }
        return out
    }
}

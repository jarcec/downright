import AppKit
import MarkdownKit

/// Renders Markdown to an attributed string for the pasteboard: markers removed, real
/// fonts and links, list prefixes, monospace code. Not a layout engine — tables become
/// tab-separated rows and images their alt text.
@MainActor
public enum RichTextExporter {
    public static func attributedString(markdown: String, theme: Theme = Theme(), dialect: Dialect = .gfm) -> NSAttributedString {
        let doc = MarkdownParser.parse(markdown, dialect: dialect)
        let out = NSMutableAttributedString()
        let src = markdown as NSString
        var listDepth = 0

        func base(_ font: NSFont, indent: CGFloat = 0, spacingAfter: CGFloat = 6) -> [NSAttributedString.Key: Any] {
            let ps = NSMutableParagraphStyle()
            ps.paragraphSpacing = spacingAfter
            ps.headIndent = indent
            ps.firstLineHeadIndent = indent
            return [.font: font, .foregroundColor: theme.textColor, .paragraphStyle: ps]
        }

        func appendInlines(_ nodes: [Inline], attrs: [NSAttributedString.Key: Any]) {
            for n in nodes {
                switch n.kind {
                case .text:
                    out.append(NSAttributedString(string: src.substring(with: n.range), attributes: attrs))
                case .softBreak:
                    out.append(NSAttributedString(string: " ", attributes: attrs))
                case .hardBreak:
                    out.append(NSAttributedString(string: "\n", attributes: attrs))
                case .escape:
                    out.append(NSAttributedString(string: src.substring(with: NSRange(location: n.range.location + 1, length: n.range.length - 1)), attributes: attrs))
                case .code:
                    var a = attrs
                    let f = attrs[.font] as? NSFont ?? theme.bodyFont
                    a[.font] = NSFont.monospacedSystemFont(ofSize: f.pointSize * 0.92, weight: .regular)
                    a[.backgroundColor] = theme.codeBackground
                    out.append(NSAttributedString(string: content(of: n), attributes: a))
                case .emphasis:
                    var a = attrs; a[.font] = (attrs[.font] as? NSFont ?? theme.bodyFont).adding(.italic)
                    appendInlines(n.children, attrs: a)
                case .strong:
                    var a = attrs; a[.font] = (attrs[.font] as? NSFont ?? theme.bodyFont).adding(.bold)
                    appendInlines(n.children, attrs: a)
                case .strikethrough:
                    var a = attrs; a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    appendInlines(n.children, attrs: a)
                case .link(let dest, _):
                    var a = attrs
                    if let u = DecorationEngine.url(dest) { a[.link] = u }
                    a[.foregroundColor] = theme.accentColor
                    appendInlines(n.children, attrs: a)
                case .autolink(let dest):
                    var a = attrs
                    if let u = DecorationEngine.url(dest) { a[.link] = u }
                    a[.foregroundColor] = theme.accentColor
                    out.append(NSAttributedString(string: dest.hasPrefix("mailto:") ? String(dest.dropFirst(7)) : dest, attributes: a))
                case .image(_, let alt):
                    out.append(NSAttributedString(string: alt, attributes: attrs))
                case .html:
                    out.append(NSAttributedString(string: src.substring(with: n.range), attributes: attrs))
                }
            }
        }

        /// Text of a node with its markers stripped (code spans).
        func content(of n: Inline) -> String {
            var s = src.substring(with: n.range)
            for m in n.markerRanges.sorted(by: { $0.location > $1.location }) {
                let rel = NSRange(location: m.location - n.range.location, length: m.length)
                s = (s as NSString).replacingCharacters(in: rel, with: "")
            }
            return s.trimmingCharacters(in: .whitespaces)
        }

        func lineText(_ ranges: [NSRange]) -> String {
            ranges.map { src.substring(with: $0) }.joined(separator: "\n")
        }

        func render(_ blocks: [Block], indent: CGFloat) {
            for b in blocks {
                switch b.kind {
                case .heading(let level), .setextHeading(let level, _):
                    appendInlines(b.inlines, attrs: base(theme.headingFont(level), indent: indent, spacingAfter: 8))
                    out.append(NSAttributedString(string: "\n"))
                case .paragraph:
                    appendInlines(b.inlines, attrs: base(theme.bodyFont, indent: indent))
                    out.append(NSAttributedString(string: "\n"))
                case .blockQuote:
                    render(b.children, indent: indent + 24)
                case .list(let ordered, _, let start):
                    listDepth += 1
                    for (i, item) in b.children.enumerated() {
                        guard case .listItem(_, _, let task) = item.kind else { continue }
                        var prefix = ordered ? "\(start + i). " : "•  "
                        if let t = task { prefix += t.state == .checked ? "☑ " : "☐ " }
                        // First paragraph inline with the prefix; further children below it.
                        let attrs = base(theme.bodyFont, indent: indent + CGFloat(listDepth - 1) * 20, spacingAfter: 2)
                        out.append(NSAttributedString(string: prefix, attributes: attrs))
                        var rest = item.children
                        if let first = rest.first, case .paragraph = first.kind {
                            appendInlines(first.inlines, attrs: attrs)
                            rest.removeFirst()
                        }
                        out.append(NSAttributedString(string: "\n"))
                        render(rest, indent: indent + CGFloat(listDepth) * 20)
                    }
                    listDepth -= 1
                case .fencedCode, .indentedCode, .htmlBlock, .frontmatter:
                    var a = base(theme.monoFont, indent: indent)
                    a[.backgroundColor] = theme.codeBlockBackground
                    out.append(NSAttributedString(string: lineText(b.contentRanges) + "\n", attributes: a))
                case .thematicBreak:
                    out.append(NSAttributedString(string: "———\n", attributes: base(theme.bodyFont, indent: indent)))
                case .table(let t):
                    for (ri, row) in t.allRows.enumerated() {
                        let f = ri == 0 ? theme.bodyFont.adding(.bold) : theme.bodyFont
                        let attrs = base(f, indent: indent, spacingAfter: 2)
                        for (ci, cell) in row.cells.enumerated() {
                            if ci > 0 { out.append(NSAttributedString(string: "\t", attributes: attrs)) }
                            appendInlines(cell.inlines, attrs: attrs)
                        }
                        out.append(NSAttributedString(string: "\n"))
                    }
                case .listItem:
                    render(b.children, indent: indent)
                case .linkReferenceDefinition:
                    break
                }
            }
        }
        render(doc.blocks, indent: 0)
        // Trim a single trailing newline so pasting doesn't add a blank line.
        if out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }
}

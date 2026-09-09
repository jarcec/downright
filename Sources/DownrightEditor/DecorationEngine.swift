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
    private let spaceWidth: CGFloat

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
                        d.substitutions.append((marker.location, 0x2022))  // •
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

        case .table:
            d.role = .tableRow
            d.styles.append(StyleRun(pr, .font(theme.monoFont)))
            d.lineHeightMultiple = 1.2

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
        walk(block.inlines)
    }

    static func url(_ s: String) -> URL? {
        if let u = URL(string: s), u.scheme != nil { return u }
        if let enc = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let u = URL(string: enc), u.scheme != nil { return u }
        return nil
    }
}

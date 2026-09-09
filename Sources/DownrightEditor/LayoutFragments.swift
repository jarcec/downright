import AppKit

/// Block-level drawing: code-block backgrounds, quote bars, rules, frontmatter tint, and
/// zero-height hidden lines (TRD §6.5, R9).
final class DecoratedLayoutFragment: NSTextLayoutFragment {
    enum Appearance: Equatable {
        case plain
        case hidden
        case codeBlock(info: String, top: Bool, bottom: Bool)
        case rule
        case frontmatter(top: Bool, bottom: Bool)
    }

    var appearance: Appearance = .plain
    var quoteDepth = 0
    var theme = Theme()

    override var layoutFragmentFrame: CGRect {
        var f = super.layoutFragmentFrame
        switch appearance {
        case .hidden: f.size.height = 0
        case .rule: f.size.height = max(f.size.height, 22)   // concealed text would collapse the line
        default: break
        }
        return f
    }

    /// Full container width. The fragment's own width tracks the *text*, which for a
    /// concealed line is ~0 — backgrounds and rules must span the column instead.
    private var columnWidth: CGFloat {
        textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width
    }

    /// An indented paragraph's fragment frame starts at the indent, not at the column
    /// edge; block decorations are drawn relative to the column, so shift back by it.
    private var indentOffset: CGFloat { super.layoutFragmentFrame.origin.x }

    override var renderingSurfaceBounds: CGRect {
        var b = super.renderingSurfaceBounds
        b = b.union(CGRect(x: -indentOffset - 8, y: 0, width: columnWidth + 16, height: super.layoutFragmentFrame.height))
        return b
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if appearance == .hidden { return }
        let width = columnWidth
        let height = super.layoutFragmentFrame.height
        let lineRect = CGRect(x: point.x - indentOffset, y: point.y, width: width, height: height)

        context.saveGState()
        switch appearance {
        case .plain, .hidden:
            break
        case .codeBlock(let info, let top, let bottom):
            fill(lineRect.insetBy(dx: -6, dy: 0), color: theme.codeBlockBackground, top: top, bottom: bottom, radius: 6, in: context)
            if top, !info.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: theme.secondaryColor]
                let s = NSAttributedString(string: info, attributes: attrs)
                let size = s.size()
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                s.draw(at: CGPoint(x: lineRect.maxX - size.width - 2, y: lineRect.minY + 2))
                NSGraphicsContext.restoreGraphicsState()
            }
        case .frontmatter(let top, let bottom):
            fill(lineRect.insetBy(dx: -6, dy: 0), color: theme.frontmatterBackground, top: top, bottom: bottom, radius: 6, in: context)
        case .rule:
            context.setFillColor(theme.rule.cgColor)
            let mid = point.y + layoutFragmentFrame.height / 2
            context.fill(CGRect(x: lineRect.minX, y: mid - 0.5, width: width, height: 1))
        }
        if quoteDepth > 0 {
            context.setFillColor(theme.quoteBar.cgColor)
            for i in 0..<quoteDepth {
                let x = lineRect.minX + CGFloat(i) * theme.quoteIndent + 3
                context.fill(CGRect(x: x, y: lineRect.minY, width: 3, height: height))
            }
        }
        context.restoreGState()

        if appearance == .rule { return }   // text is concealed anyway
        super.draw(at: point, in: context)
    }

    private func fill(_ rect: CGRect, color: NSColor, top: Bool, bottom: Bool, radius: CGFloat, in ctx: CGContext) {
        ctx.setFillColor(color.cgColor)
        if !top && !bottom {
            ctx.fill(rect); return
        }
        var r = rect
        if !top { r.origin.y -= radius; r.size.height += radius }
        if !bottom { r.size.height += radius }
        ctx.saveGState()
        ctx.clip(to: rect)
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }
}

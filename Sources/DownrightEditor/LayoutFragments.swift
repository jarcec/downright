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
        case table(boundaries: [CGFloat], header: Bool, top: Bool, bottom: Bool)
    }

    var appearance: Appearance = .plain
    var quoteDepth = 0
    var quoteTop = false
    var quoteBottom = false
    var listGuides: [CGFloat] = []
    var theme = Theme()
    /// Table rows: how far their table is scrolled sideways (the layout is shifted by it).
    var tableScroll: CGFloat = 0

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
    /// (A scrolled table row's frame starts left of the column by its offset, so this
    /// brings it back to the column edge too.)
    private var indentOffset: CGFloat { super.layoutFragmentFrame.origin.x }

    override var renderingSurfaceBounds: CGRect {
        var b = super.renderingSurfaceBounds
        b = b.union(CGRect(x: -indentOffset - 8, y: 0, width: columnWidth + 16, height: super.layoutFragmentFrame.height))
        if case .table(let boundaries, _, _, _) = appearance, let last = boundaries.last {
            b = b.union(CGRect(x: -indentOffset - 8, y: 0, width: last + 16, height: super.layoutFragmentFrame.height))
        }
        return b
    }

    /// Height of the text lines proper. The document's final paragraph carries an extra
    /// empty line fragment (the caret slot after the trailing newline); block decorations
    /// must not paint it, or the last table row / code line grows a phantom row.
    private var contentHeight: CGFloat {
        var h = super.layoutFragmentFrame.height
        if textLineFragments.count > 1, let last = textLineFragments.last, last.characterRange.length == 0 {
            h -= last.typographicBounds.height
        }
        return h
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if appearance == .hidden { return }
        let width = columnWidth
        let height = contentHeight
        let lineRect = CGRect(x: point.x - indentOffset, y: point.y, width: width, height: height)

        context.saveGState()
        // A table wider than the column is cut at the column's edges and scrolls within them.
        var tableOverflow: (left: Bool, right: Bool)? = nil
        if case .table(let boundaries, _, _, _) = appearance, let last = boundaries.last, last > width + 0.5 || tableScroll > 0 {
            context.clip(to: CGRect(x: lineRect.minX - 1, y: lineRect.minY, width: width + 2, height: height))
            tableOverflow = (tableScroll > 0.5, last - tableScroll > width + 0.5)
        }
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
        case .table(let boundaries, let header, let top, let bottom):
            guard let first = boundaries.first, let last = boundaries.last else { break }
            let x0 = lineRect.minX + first - tableScroll, x1 = lineRect.minX + last - tableScroll
            if header {
                context.setFillColor(theme.codeBlockBackground.cgColor)
                context.fill(CGRect(x: x0, y: lineRect.minY, width: x1 - x0, height: height))
            }
            context.setFillColor(theme.rule.cgColor)
            for b in boundaries {
                context.fill(CGRect(x: lineRect.minX + b - tableScroll - 0.5, y: lineRect.minY, width: 1, height: height))
            }
            if top { context.fill(CGRect(x: x0, y: lineRect.minY, width: x1 - x0, height: 1)) }
            let thickness: CGFloat = header ? 1.5 : 1
            context.fill(CGRect(x: x0, y: lineRect.maxY - thickness, width: x1 - x0, height: thickness))
            _ = bottom
        }
        if quoteDepth > 0 {
            // Tinted, rounded background like a code block, with a bar per nesting level.
            // The whole quote is clipped to one rounded shape so the outer bar's corners
            // round with the background.
            let rect = CGRect(x: lineRect.minX - 6, y: lineRect.minY, width: width + 12, height: height)
            roundedClip(rect, top: quoteTop, bottom: quoteBottom, radius: 6, in: context)
            context.setFillColor(theme.quoteBackground.cgColor)
            context.fill(rect)
            context.setFillColor(theme.quoteBar.cgColor)
            for i in 0..<quoteDepth {
                let x = i == 0 ? rect.minX : lineRect.minX + CGFloat(i) * theme.quoteIndent + 3
                context.fill(CGRect(x: x, y: lineRect.minY, width: i == 0 ? 4 : 3, height: height))
            }
        }
        if !listGuides.isEmpty {
            context.setFillColor(theme.listGuide.cgColor)
            for x in listGuides {
                context.fill(CGRect(x: (lineRect.minX + x - 0.5).rounded(), y: lineRect.minY, width: 1, height: height))
            }
        }
        context.restoreGState()

        if appearance == .rule { return }   // text is concealed anyway
        guard let overflow = tableOverflow else { return super.draw(at: point, in: context) }
        // A wide table's text is cut at the column too, with the edges faded so the
        // overflow reads as scrollable.
        context.saveGState()
        context.clip(to: CGRect(x: lineRect.minX - 1, y: lineRect.minY, width: width + 2, height: height))
        super.draw(at: point, in: context)
        do {
            let fade: CGFloat = 24
            let colors = [theme.backgroundColor.withAlphaComponent(0).cgColor, theme.backgroundColor.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                if overflow.right {
                    context.saveGState()
                    context.clip(to: CGRect(x: lineRect.maxX - fade, y: lineRect.minY, width: fade, height: height))
                    context.drawLinearGradient(gradient, start: CGPoint(x: lineRect.maxX - fade, y: 0), end: CGPoint(x: lineRect.maxX, y: 0), options: [])
                    context.restoreGState()
                }
                if overflow.left {
                    context.saveGState()
                    context.clip(to: CGRect(x: lineRect.minX, y: lineRect.minY, width: fade, height: height))
                    context.drawLinearGradient(gradient, start: CGPoint(x: lineRect.minX + fade, y: 0), end: CGPoint(x: lineRect.minX, y: 0), options: [])
                    context.restoreGState()
                }
            }
        }
        context.restoreGState()
    }

    private func fill(_ rect: CGRect, color: NSColor, top: Bool, bottom: Bool, radius: CGFloat, in ctx: CGContext) {
        ctx.setFillColor(color.cgColor)
        if !top && !bottom {
            ctx.fill(rect); return
        }
        ctx.saveGState()
        roundedClip(rect, top: top, bottom: bottom, radius: radius, in: ctx)
        ctx.fill(rect)
        ctx.restoreGState()
    }

    /// Clip to `rect` with the top and/or bottom corners rounded (a middle slice of a
    /// multi-line block rounds neither).
    private func roundedClip(_ rect: CGRect, top: Bool, bottom: Bool, radius: CGFloat, in ctx: CGContext) {
        ctx.clip(to: rect)
        guard top || bottom else { return }
        var r = rect
        if !top { r.origin.y -= radius; r.size.height += radius }
        if !bottom { r.size.height += radius }
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
    }
}

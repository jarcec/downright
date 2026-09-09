import AppKit
import MarkdownKit

/// The TextKit 2 seam (TRD §6.2). Produces the *display* paragraph for a backing range
/// while the backing store stays pristine. Enforces the M0 invariant: same length.
@MainActor
public final class MarkdownContentStorageDelegate: NSObject, @preconcurrency NSTextContentStorageDelegate {
    public var engine: DecorationEngine?
    public var revealed: [NSRange] = []
    public var revealAll = false

    public func isRevealed(_ range: NSRange) -> Bool {
        if revealAll { return true }
        for r in revealed where r.location < range.end && range.location < r.end { return true }
        return false
    }

    public func textContentStorage(_ textContentStorage: NSTextContentStorage,
                                   textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let engine, let backing = textContentStorage.textStorage else { return nil }
        let d = engine.decoration(forParagraphAt: range.location)
        let out = NSMutableAttributedString(string: backing.attributedSubstring(from: range).string)
        let revealed = isRevealed(range)

        for run in d.styles { Self.apply(run, to: out, base: range) }
        if revealed {
            for run in d.markerStyles { Self.apply(run, to: out, base: range) }
        } else {
            for (offset, ch) in d.substitutions {
                let i = offset - range.location
                guard i >= 0, i < out.length else { continue }
                let attrs = out.attributes(at: i, effectiveRange: nil)
                out.replaceCharacters(in: NSRange(location: i, length: 1),
                                      with: NSAttributedString(string: String(utf16CodeUnits: [ch], count: 1), attributes: attrs))
            }
            for run in d.concealedStyles { Self.apply(run, to: out, base: range) }
            for r in d.conceal {
                guard let rel = Self.relative(r, base: range) else { continue }
                out.addAttributes([.font: Theme.concealedFont, .foregroundColor: Theme.concealedColor], range: rel)
            }
        }

        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = d.lineHeightMultiple
        ps.headIndent = d.headIndent
        ps.firstLineHeadIndent = d.firstLineHeadIndent
        ps.paragraphSpacingBefore = d.spacingBefore
        out.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: out.length))

        assert(out.length == range.length, "display paragraph must be length-identical to its source (M0)")
        return NSTextParagraph(attributedString: out)
    }

    // MARK: - Applying styles

    static func relative(_ r: NSRange, base: NSRange) -> NSRange? {
        let start = max(r.location, base.location)
        let end = min(r.location + r.length, base.location + base.length)
        guard end > start else { return nil }
        return NSRange(location: start - base.location, length: end - start)
    }

    static func apply(_ run: StyleRun, to out: NSMutableAttributedString, base: NSRange) {
        guard let rel = relative(run.range, base: base) else { return }
        switch run.op {
        case .font(let f):
            out.addAttribute(.font, value: f, range: rel)
        case .foreground(let c):
            out.addAttribute(.foregroundColor, value: c, range: rel)
        case .background(let c):
            out.addAttribute(.backgroundColor, value: c, range: rel)
        case .link(let url):
            out.addAttribute(.link, value: url, range: rel)
        case .strikethrough:
            out.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: rel)
        case .baselineOffset(let v):
            out.addAttribute(.baselineOffset, value: v, range: rel)
        case .traits(let traits):
            out.enumerateAttribute(.font, in: rel) { value, r, _ in
                let f = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                out.addAttribute(.font, value: f.adding(traits), range: r)
            }
        case .mono:
            out.enumerateAttribute(.font, in: rel) { value, r, _ in
                let f = (value as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
                let traits = f.fontDescriptor.symbolicTraits
                var mono = NSFont.monospacedSystemFont(ofSize: f.pointSize * 0.92, weight: traits.contains(.bold) ? .bold : .regular)
                if traits.contains(.italic) { mono = mono.adding(.italic) }
                out.addAttribute(.font, value: mono, range: r)
            }
        }
    }
}

extension NSFont {
    func adding(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let desc = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: desc, size: pointSize) ?? self
    }
}

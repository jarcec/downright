import AppKit

/// Fonts and colours for rendering. Colours are dynamic (light/dark) where they matter.
public struct Theme: @unchecked Sendable, Equatable {
    public var bodySize: CGFloat = 15
    public var lineHeightMultiple: CGFloat = 1.3
    public var quoteIndent: CGFloat = 18

    /// Revealed syntax markers (`**`, `#`, `>`). Default green; user-configurable.
    public var markerColor: NSColor = Theme.defaultMarkerColor
    /// Vim normal/visual block cursor. Defaults to a lighter tone of the marker colour so
    /// the two read as one system; user-configurable.
    public var vimCursorColor: NSColor = Theme.defaultVimCursorColor

    public static var defaultMarkerColor: NSColor { .systemGreen }
    public static var defaultVimCursorColor: NSColor { NSColor.systemGreen.withAlphaComponent(0.4) }

    public init() {}

    public static func == (a: Theme, b: Theme) -> Bool {
        a.bodySize == b.bodySize && a.lineHeightMultiple == b.lineHeightMultiple && a.quoteIndent == b.quoteIndent
            && a.markerColor.hexString == b.markerColor.hexString && a.vimCursorColor.hexString == b.vimCursorColor.hexString
    }

    public var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    public var monoFont: NSFont { .monospacedSystemFont(ofSize: bodySize - 1.5, weight: .regular) }
    public var smallMonoFont: NSFont { .monospacedSystemFont(ofSize: bodySize - 3, weight: .regular) }

    public func headingFont(_ level: Int) -> NSFont {
        let scale: [CGFloat] = [1.85, 1.5, 1.25, 1.1, 1.0, 0.95]
        let l = min(max(level, 1), 6)
        return .systemFont(ofSize: (bodySize * scale[l - 1]).rounded(), weight: l <= 2 ? .bold : .semibold)
    }

    public var textColor: NSColor { .labelColor }
    public var secondaryColor: NSColor { .secondaryLabelColor }
    public var accentColor: NSColor { .linkColor }
    public var listMarkerColor: NSColor { .secondaryLabelColor }

    public var codeBackground: NSColor {
        NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.05)
        }
    }
    public var codeBlockBackground: NSColor {
        NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.035)
        }
    }
    public var frontmatterBackground: NSColor {
        NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.6, green: 0.7, blue: 1, alpha: 0.07) : NSColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 0.05)
        }
    }
    public var quoteBar: NSColor { .separatorColor }

    /// Code highlighting palette (system colours, so they adapt to light/dark).
    public func color(for token: CodeToken) -> NSColor {
        switch token {
        case .keyword: return .systemPurple
        case .type: return .systemTeal
        case .string: return .systemRed
        case .comment: return .secondaryLabelColor
        case .number: return .systemBlue
        case .key: return .systemIndigo
        case .variable: return .systemOrange
        case .added: return .systemGreen
        case .removed: return .systemRed
        case .meta: return .tertiaryLabelColor
        case .tag: return .systemPurple
        case .attribute: return .systemBrown
        }
    }
    public var rule: NSColor { .separatorColor }

    /// The concealment constants (TRD OQ-T7). Zero advance, invisible, length preserved.
    public static var concealedFont: NSFont { .systemFont(ofSize: 0.01) }
    public static var concealedColor: NSColor { .clear }

    // MARK: - Colour ↔ hex (settings file)

    /// Parse `#RRGGBB` or `#RRGGBBAA` (sRGB). Nil for anything else.
    public static func color(hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return nil }
        let hasAlpha = h.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Width of one space in the body font; used to approximate column-based indents.
    public var spaceWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: bodyFont]).width
    }
}

public extension NSColor {
    /// `#RRGGBBAA` in sRGB (resolved for the current appearance if the colour is dynamic).
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func b(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent), b(c.alphaComponent))
    }
}

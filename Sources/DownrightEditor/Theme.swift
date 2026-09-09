import AppKit

/// Fonts and colours for rendering. Colours are dynamic (light/dark) where they matter.
public struct Theme: Sendable {
    public var bodySize: CGFloat = 15
    public var lineHeightMultiple: CGFloat = 1.3
    public var quoteIndent: CGFloat = 18

    public init() {}

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
    /// Revealed syntax markers (`**`, `#`, `>`): a green tint so the scaffolding that
    /// just appeared under the caret is easy to spot.
    public var markerColor: NSColor { .systemGreen }
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

    /// Width of one space in the body font; used to approximate column-based indents.
    public var spaceWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: bodyFont]).width
    }
}

import AppKit

/// Every colour the editor draws with. A theme is a value for each of these; nothing in
/// the editor reaches for a system colour on its own, so a theme fully describes the page.
public enum ColorToken: String, CaseIterable, Sendable {
    // Page
    case background, text, secondary, faint
    // Markdown
    case accent, marker, cursor, listMarker, rule
    // Blocks
    case inlineCode, codeBlock, quote, quoteBar, frontmatter
    // Code syntax highlighting
    case codeKeyword, codeType, codeString, codeComment, codeNumber, codeKey
    case codeVariable, codeAdded, codeRemoved, codeMeta, codeTag, codeAttribute

    public enum Group: String, CaseIterable, Sendable {
        case page = "Page", markdown = "Markdown", blocks = "Blocks", code = "Code syntax"
    }

    public var group: Group {
        switch self {
        case .background, .text, .secondary, .faint: return .page
        case .accent, .marker, .cursor, .listMarker, .rule: return .markdown
        case .inlineCode, .codeBlock, .quote, .quoteBar, .frontmatter: return .blocks
        default: return .code
        }
    }

    /// Label for the settings UI.
    public var title: String {
        switch self {
        case .background: return "Background"
        case .text: return "Text"
        case .secondary: return "Dimmed text"
        case .faint: return "Line numbers"
        case .accent: return "Links"
        case .marker: return "Syntax markers"
        case .cursor: return "Vim cursor"
        case .listMarker: return "List markers"
        case .rule: return "Rules & guides"
        case .inlineCode: return "Inline code"
        case .codeBlock: return "Code block"
        case .quote: return "Quote background"
        case .quoteBar: return "Quote bar"
        case .frontmatter: return "Frontmatter"
        case .codeKeyword: return "Keyword"
        case .codeType: return "Type"
        case .codeString: return "String"
        case .codeComment: return "Comment"
        case .codeNumber: return "Number"
        case .codeKey: return "Key"
        case .codeVariable: return "Variable"
        case .codeAdded: return "Added"
        case .codeRemoved: return "Removed"
        case .codeMeta: return "Meta"
        case .codeTag: return "Tag"
        case .codeAttribute: return "Attribute"
        }
    }

    /// Colours that sit under text and may be translucent.
    public var supportsOpacity: Bool {
        switch self {
        case .cursor, .inlineCode, .codeBlock, .quote, .quoteBar, .frontmatter, .rule: return true
        default: return false
        }
    }
}

/// A complete set of colours, one per `ColorToken`.
public struct Palette: @unchecked Sendable {
    private var colors: [ColorToken: NSColor]

    public init(_ colors: [ColorToken: NSColor]) { self.colors = colors }

    public subscript(token: ColorToken) -> NSColor {
        get { colors[token] ?? .labelColor }
        set { colors[token] = newValue }
    }

    /// `#RRGGBBAA` per token, resolved for the current appearance — what the settings
    /// file stores for a custom theme.
    public var hexValues: [String: String] {
        var out: [String: String] = [:]
        for token in ColorToken.allCases { out[token.rawValue] = self[token].hexString }
        return out
    }

    /// This palette with every parseable value in `hexValues` applied over it, so a
    /// partial (or hand-edited) settings file still yields a complete palette.
    public func applying(hexValues: [String: String]) -> Palette {
        var out = self
        for (key, hex) in hexValues {
            guard let token = ColorToken(rawValue: key), let color = Theme.color(hex: hex) else { continue }
            out[token] = color
        }
        return out
    }

    /// True when the background is dark, which is what the app's own chrome follows.
    public var isDark: Bool {
        let c = self[.background].usingColorSpace(.sRGB) ?? .white
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent < 0.5
    }
}

extension Palette: Equatable {
    /// Compared as resolved values: two dynamic palettes that draw the same are the same.
    public static func == (a: Palette, b: Palette) -> Bool {
        ColorToken.allCases.allSatisfy { a[$0].hexString == b[$0].hexString }
    }
}

// MARK: - The built-in palettes

public extension Palette {
    /// "Tabletop, on Paper" in daylight: a warm cream ground with ink-brown text, the
    /// palette Downright borrows from BoardGamePad.
    static let paper = Palette([
        .background: hex("#F7F0E3"),          // paper
        .text: hex("#2A241D"),                // ink
        .secondary: hex("#625A4B"),           // muted
        .faint: hex("#736A5A", alpha: 0.7),   // subtle
        .accent: hex("#AC5534"),              // terracotta, deepened so it can carry text
        .marker: hex("#2F897A"),              // teal
        .cursor: hex("#2F897A", alpha: 0.35),
        .listMarker: hex("#736A5A"),
        .rule: hex("#736A5A", alpha: 0.3),
        .inlineCode: hex("#ECE2CF"),          // sunk
        .codeBlock: hex("#ECE2CF"),
        .quote: hex("#ECE2CF", alpha: 0.6),
        .quoteBar: hex("#736A5A", alpha: 0.5),
        .frontmatter: hex("#4F6DA8", alpha: 0.07),
        .codeKeyword: hex("#7B5AA6"),
        .codeType: hex("#2F897A"),
        .codeString: hex("#B8402E"),
        .codeComment: hex("#625A4B"),
        .codeNumber: hex("#4F6DA8"),
        .codeKey: hex("#8C4C6D"),
        .codeVariable: hex("#D97E2B"),
        .codeAdded: hex("#5F8C4C"),
        .codeRemoved: hex("#B8402E"),
        .codeMeta: hex("#736A5A"),
        .codeTag: hex("#7B5AA6"),
        .codeAttribute: hex("#8A5A3B"),
    ])

    /// The same palette folded over on itself for night: the ground stays warm (hue ~30°)
    /// instead of going flat grey. Code hues that BoardGamePad fixes in both appearances
    /// are lightened here, because here they have to letter a dark ground.
    static let ink = Palette([
        .background: hex("#1A1611"),
        .text: hex("#EDE4D2"),
        .secondary: hex("#A2957F"),
        .faint: hex("#918676", alpha: 0.7),
        .accent: hex("#E08050"),
        .marker: hex("#43A18E"),
        .cursor: hex("#43A18E", alpha: 0.35),
        .listMarker: hex("#918676"),
        .rule: hex("#918676", alpha: 0.3),
        .inlineCode: hex("#241F18"),          // card: a lifted surface at night
        .codeBlock: hex("#241F18"),
        .quote: hex("#241F18", alpha: 0.7),
        .quoteBar: hex("#918676", alpha: 0.5),
        .frontmatter: hex("#7E9AD2", alpha: 0.1),
        .codeKeyword: hex("#A98BD0"),
        .codeType: hex("#43A18E"),
        .codeString: hex("#D9644D"),
        .codeComment: hex("#A2957F"),
        .codeNumber: hex("#7E9AD2"),
        .codeKey: hex("#BE7398"),
        .codeVariable: hex("#E39B5A"),
        .codeAdded: hex("#7FB068"),
        .codeRemoved: hex("#D9644D"),
        .codeMeta: hex("#918676"),
        .codeTag: hex("#A98BD0"),
        .codeAttribute: hex("#C08A62"),
    ])

    /// A custom palette: the user's colours over the ground of the slot it fills — Paper
    /// for the light one, Ink for the dark one — so a file that names only a background
    /// still comes out legible instead of cream boxes under pale text. A background that
    /// disagrees with its slot wins: the other ground is used.
    static func custom(_ hexValues: [String: String], base: Palette = .paper) -> Palette {
        var ground = base
        if let background = hexValues[ColorToken.background.rawValue].flatMap({ Theme.color(hex: $0) }),
           Palette([.background: background]).isDark != base.isDark {
            ground = base.isDark ? .paper : .ink
        }
        return ground.applying(hexValues: hexValues)
    }

    /// One palette of dynamic colours: `light` by day, `dark` by night. The window then
    /// follows the system appearance without anything being rebuilt.
    static func dynamic(light: Palette, dark: Palette) -> Palette {
        var out: [ColorToken: NSColor] = [:]
        for token in ColorToken.allCases {
            out[token] = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark[token] : light[token]
            }
        }
        return Palette(out)
    }

    /// The default pairing: Paper by day, Ink by night.
    static let system = Palette.dynamic(light: .paper, dark: .ink)

    private static func hex(_ s: String, alpha: CGFloat = 1) -> NSColor {
        let c = Theme.color(hex: s) ?? .labelColor
        return alpha < 1 ? c.withAlphaComponent(alpha) : c
    }
}

/// Which of the two theme slots the app draws with.
public enum Appearance: String, CaseIterable, Sendable, Identifiable {
    /// Follow macOS: the light slot by day, the dark one by night.
    case system, light, dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// The two slots a theme can fill.
public enum ThemeSlot: String, CaseIterable, Sendable, Identifiable {
    case light, dark

    public var id: String { rawValue }
    public var title: String { self == .light ? "Light" : "Dark" }
    /// What a custom palette in this slot builds on when it leaves colours out.
    public var ground: Palette { self == .light ? .paper : .ink }
}

/// A theme that can fill either slot. `custom` is the slot's own set of colours.
public enum ThemeChoice: String, CaseIterable, Sendable, Identifiable {
    case paper, ink, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .paper: return "Paper"
        case .ink: return "Ink"
        case .custom: return "Custom"
        }
    }
}

/// The whole colour selection: which slot is in force, what fills each one, and the
/// user's own colours for the slots set to Custom.
public struct ThemeSelection: Equatable, Sendable {
    public var appearance: Appearance
    public var light: ThemeChoice
    public var dark: ThemeChoice
    /// `ColorToken.rawValue` → `#RRGGBBAA`, per slot. Anything missing comes from the
    /// slot's ground, so a partial set is still a whole palette.
    public var customLight: [String: String]
    public var customDark: [String: String]

    public init(appearance: Appearance = .system, light: ThemeChoice = .paper, dark: ThemeChoice = .ink,
                customLight: [String: String] = [:], customDark: [String: String] = [:]) {
        self.appearance = appearance
        self.light = light
        self.dark = dark
        self.customLight = customLight
        self.customDark = customDark
    }

    public func choice(for slot: ThemeSlot) -> ThemeChoice { slot == .light ? light : dark }
    public func custom(for slot: ThemeSlot) -> [String: String] { slot == .light ? customLight : customDark }

    /// What a slot draws with, whichever slot is actually in force.
    public func palette(for slot: ThemeSlot) -> Palette {
        switch choice(for: slot) {
        case .paper: return .paper
        case .ink: return .ink
        case .custom: return .custom(custom(for: slot), base: slot.ground)
        }
    }

    /// The palette in force. In System it is one set of dynamic colours, so the window
    /// follows macOS without anything being rebuilt.
    public var palette: Palette {
        switch appearance {
        case .light: return palette(for: .light)
        case .dark: return palette(for: .dark)
        case .system: return .dynamic(light: palette(for: .light), dark: palette(for: .dark))
        }
    }

    /// The appearance the app's own chrome runs in: whatever the page it frames is. Nil
    /// means follow macOS, which is what System's dynamic palette does too.
    public var chrome: NSAppearance? {
        switch appearance {
        case .system: return nil
        case .light: return NSAppearance(named: palette(for: .light).isDark ? .darkAqua : .aqua)
        case .dark: return NSAppearance(named: palette(for: .dark).isDark ? .darkAqua : .aqua)
        }
    }
}

/// Fonts and colours for rendering.
public struct Theme: @unchecked Sendable, Equatable {
    public var bodySize: CGFloat = 15
    public var lineHeightMultiple: CGFloat = 1.3
    public var quoteIndent: CGFloat = 18
    public var palette: Palette = .system

    public init() {}
    public init(palette: Palette) { self.palette = palette }
    public init(_ selection: ThemeSelection) { self.palette = selection.palette }

    public static func == (a: Theme, b: Theme) -> Bool {
        a.bodySize == b.bodySize && a.lineHeightMultiple == b.lineHeightMultiple
            && a.quoteIndent == b.quoteIndent && a.palette == b.palette
    }

    // MARK: - Fonts

    public var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    public var monoFont: NSFont { .monospacedSystemFont(ofSize: bodySize - 1.5, weight: .regular) }
    public var smallMonoFont: NSFont { .monospacedSystemFont(ofSize: bodySize - 3, weight: .regular) }

    public func headingFont(_ level: Int) -> NSFont {
        let scale: [CGFloat] = [1.85, 1.5, 1.25, 1.1, 1.0, 0.95]
        let l = min(max(level, 1), 6)
        return .systemFont(ofSize: (bodySize * scale[l - 1]).rounded(), weight: l <= 2 ? .bold : .semibold)
    }

    // MARK: - Colours

    public var backgroundColor: NSColor { palette[.background] }
    public var textColor: NSColor { palette[.text] }
    public var secondaryColor: NSColor { palette[.secondary] }
    /// Line numbers and fold chevrons: quieter than `secondaryColor`.
    public var faintColor: NSColor { palette[.faint] }
    public var accentColor: NSColor { palette[.accent] }
    /// Revealed syntax markers (`**`, `#`, `>`).
    public var markerColor: NSColor { palette[.marker] }
    /// Vim normal/visual block cursor.
    public var vimCursorColor: NSColor { palette[.cursor] }
    public var listMarkerColor: NSColor { palette[.listMarker] }
    public var codeBackground: NSColor { palette[.inlineCode] }
    public var codeBlockBackground: NSColor { palette[.codeBlock] }
    public var quoteBackground: NSColor { palette[.quote] }
    public var quoteBar: NSColor { palette[.quoteBar] }
    public var frontmatterBackground: NSColor { palette[.frontmatter] }
    /// Thematic breaks and table rules.
    public var rule: NSColor { palette[.rule] }
    /// Vertical guides joining the items of a nested list.
    public var listGuide: NSColor { palette[.rule] }

    /// Code highlighting palette.
    public func color(for token: CodeToken) -> NSColor {
        switch token {
        case .keyword: return palette[.codeKeyword]
        case .type: return palette[.codeType]
        case .string: return palette[.codeString]
        case .comment: return palette[.codeComment]
        case .number: return palette[.codeNumber]
        case .key: return palette[.codeKey]
        case .variable: return palette[.codeVariable]
        case .added: return palette[.codeAdded]
        case .removed: return palette[.codeRemoved]
        case .meta: return palette[.codeMeta]
        case .tag: return palette[.codeTag]
        case .attribute: return palette[.codeAttribute]
        }
    }

    /// This theme for print and the pasteboard: the same type, always on paper. A dark
    /// palette is the editor's business; what leaves the app has to read on white.
    public var forExport: Theme {
        var t = self
        t.palette = .paper
        return t
    }

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

    /// Display indent of one list nesting level, in columns. Source lists are commonly
    /// indented by two spaces, which barely reads; on screen each level steps by this much
    /// (never less than the source's own indent, so nothing shifts left).
    public var listIndentColumns: CGFloat { 4 }
}

public extension NSColor {
    /// `#RRGGBBAA` in sRGB (resolved for the current appearance if the colour is dynamic).
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func b(_ v: CGFloat) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent), b(c.alphaComponent))
    }
}

import AppKit
import MarkdownKit

public enum StyleOp {
    case font(NSFont)
    case traits(NSFontDescriptor.SymbolicTraits)
    /// Switch to the monospace face, preserving the current point size.
    case mono
    case foreground(NSColor)
    case background(NSColor)
    case link(URL)
    case strikethrough
    case baselineOffset(CGFloat)
}

public struct StyleRun {
    public var range: NSRange
    public var op: StyleOp
    public init(_ range: NSRange, _ op: StyleOp) { self.range = range; self.op = op }
}

/// What the layout-fragment provider needs to know about a source line, independent
/// of reveal state. The controller combines this with reveal state into an appearance.
public enum BlockRole: Equatable {
    case none
    case heading(Int)
    case fenceOpen(info: String)
    case fenceClose
    case codeLine(info: String, first: Bool, last: Bool)
    case indentedCode(first: Bool, last: Bool)
    case setextUnderline
    case thematicBreak
    case frontmatter(first: Bool, last: Bool)
    case tableRow
    case html
}

/// Everything needed to turn one source line into its display paragraph.
public struct ParagraphDecoration {
    /// Applied in both states, in order.
    public var styles: [StyleRun] = []
    /// Applied only when revealed: tints syntax markers.
    public var markerStyles: [StyleRun] = []
    /// Applied only when concealed. Absolute source ranges.
    public var conceal: [NSRange] = []
    /// Applied only when concealed: same-length character substitutions (plan D4).
    public var substitutions: [(offset: Int, char: unichar)] = []
    /// Applied only when concealed, after substitutions (e.g. sizing a bullet glyph).
    public var concealedStyles: [StyleRun] = []
    public var quoteDepth = 0
    public var firstLineHeadIndent: CGFloat = 0
    public var headIndent: CGFloat = 0
    public var spacingBefore: CGFloat = 0
    public var lineHeightMultiple: CGFloat = 1
    public var role: BlockRole = .none
    /// Clickable task checkbox on this line, if any.
    public var task: (range: NSRange, checked: Bool)?
    /// The list item this line begins, if any — used by Return-key list continuation.
    public var listItem: Block?

    public init() {}
}

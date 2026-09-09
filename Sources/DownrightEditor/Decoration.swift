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
    /// Extra advance after the glyph; tables use it on concealed separators to pad columns.
    case kern(CGFloat)
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
    /// `boundaries`: x positions of the column rules relative to the paragraph's left edge.
    case tableRow(boundaries: [CGFloat], header: Bool, first: Bool, last: Bool)
    case tableDelimiter
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
    /// Concealed in *both* states: table structure (pipes) never reveals; only cell text does.
    public var alwaysConceal: [NSRange] = []
    /// Line breaking for the paragraph; tables clip instead of wrapping.
    public var lineBreakMode: NSLineBreakMode = .byWordWrapping
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

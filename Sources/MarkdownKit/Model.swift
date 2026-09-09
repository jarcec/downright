import Foundation

/// A parsed Markdown document. Every range is a UTF-16 `NSRange` into the source
/// string the document was parsed from (plan decision D1), so it can be handed straight
/// to `NSTextStorage` / TextKit without translation.
public struct Document: Sendable {
    public var blocks: [Block]
    /// UTF-16 length of the source.
    public var length: Int
    /// Link reference definitions: normalised (lower-cased) label → destination.
    public var references: [String: String]
    /// The source this document was parsed from (needed by renderers that measure text).
    public var sourceString: String

    public init(blocks: [Block], length: Int, references: [String: String] = [:], sourceString: String = "") {
        self.blocks = blocks
        self.length = length
        self.references = references
        self.sourceString = sourceString
    }
}

public enum TaskState: Sendable, Equatable {
    case unchecked
    case checked
}

public struct TaskMarker: Sendable, Equatable {
    public var state: TaskState
    /// Range of the `[ ]` / `[x]` including brackets.
    public var range: NSRange
}

public enum TableAlignment: Sendable, Hashable {
    case none, left, center, right
}

public struct TableCell: Sendable {
    /// Trimmed cell content.
    public var range: NSRange
    public var inlines: [Inline]
    public init(range: NSRange, inlines: [Inline] = []) { self.range = range; self.inlines = inlines }
}

public struct TableRow: Sendable {
    /// The row's source line (excluding newline).
    public var range: NSRange
    public var cells: [TableCell]
    /// Structure between cells: `separators[i]` precedes `cells[i]`; the last one trails the
    /// final cell. Each covers the pipe and surrounding spaces; may be empty (no leading or
    /// trailing pipe). Always `cells.count + 1` entries.
    public var separators: [NSRange]
    public init(range: NSRange, cells: [TableCell], separators: [NSRange]) {
        self.range = range; self.cells = cells; self.separators = separators
    }
}

public struct Table: Sendable {
    public var header: TableRow
    /// The `|---|:-:|` line (excluding newline).
    public var delimiterRow: NSRange
    /// The delimiter line split like a row (cells are the alignment tokens).
    public var delimiter: TableRow
    public var alignments: [TableAlignment]
    public var rows: [TableRow]
    public var columnCount: Int { header.cells.count }
    public init(header: TableRow, delimiterRow: NSRange, delimiter: TableRow? = nil, alignments: [TableAlignment], rows: [TableRow]) {
        self.header = header; self.delimiterRow = delimiterRow
        self.delimiter = delimiter ?? TableRow(range: delimiterRow, cells: [], separators: [])
        self.alignments = alignments; self.rows = rows
    }
    /// Header, then body rows, in source order.
    public var allRows: [TableRow] { [header] + rows }
}

public struct Block: Sendable {
    public enum Kind: Sendable {
        case paragraph
        /// ATX heading. Markers: the opening `#…` run plus following space, and the
        /// optional closing run.
        case heading(level: Int)
        /// Setext heading. `underline` is the full underline line (excluding newline).
        case setextHeading(level: Int, underline: NSRange)
        case thematicBreak
        /// `openFence` / `closeFence` are full-line ranges (excluding newline).
        case fencedCode(openFence: NSRange, closeFence: NSRange?, info: String)
        case indentedCode
        case htmlBlock
        case blockQuote
        case list(ordered: Bool, tight: Bool, start: Int)
        /// `marker` covers the bullet or the number+delimiter. `contentIndent` is the
        /// column at which continuation lines must be indented to belong to this item.
        case listItem(marker: NSRange, contentIndent: Int, task: TaskMarker?)
        /// GFM table with cells and alignments parsed.
        case table(Table)
        /// YAML frontmatter at offset 0. Markers: the two `---` lines.
        case frontmatter
        case linkReferenceDefinition
    }

    public var kind: Kind
    /// Full source extent including the trailing newline of the last line.
    public var range: NSRange
    /// Block-level syntax to conceal when rendered: `#` runs, `>` markers (one per
    /// line), list markers, fence lines. Always absolute source ranges.
    public var markerRanges: [NSRange]
    /// For leaf blocks with inline content: the content portion of each source line,
    /// with container markers and indentation stripped. Inline parsing runs over these.
    public var contentRanges: [NSRange]
    public var children: [Block]
    public var inlines: [Inline]

    public init(kind: Kind, range: NSRange, markerRanges: [NSRange] = [],
                contentRanges: [NSRange] = [], children: [Block] = [], inlines: [Inline] = []) {
        self.kind = kind
        self.range = range
        self.markerRanges = markerRanges
        self.contentRanges = contentRanges
        self.children = children
        self.inlines = inlines
    }

    public var isContainer: Bool {
        switch kind {
        case .blockQuote, .list, .listItem: return true
        default: return false
        }
    }

    /// True for blocks whose lines are verbatim (no inline parsing, monospace).
    public var isVerbatim: Bool {
        switch kind {
        case .fencedCode, .indentedCode, .htmlBlock, .frontmatter, .table: return true
        default: return false
        }
    }
}

public struct Inline: Sendable {
    public enum Kind: Sendable {
        case text
        case softBreak
        /// Markers: the trailing spaces or backslash that produced the break.
        case hardBreak
        /// Markers: the backslash.
        case escape
        /// Markers: opening and closing backtick runs.
        case code
        case emphasis
        case strong
        case strikethrough
        /// Markers: `[`, and `](dest "title")` or `][ref]`.
        case link(destination: String, title: String?)
        /// Markers: `![`, and `](dest "title")`.
        case image(destination: String, alt: String)
        /// `<https://…>` or a bare URL (GFM). Markers: the angle brackets if present.
        case autolink(destination: String)
        case html
    }

    public var kind: Kind
    /// Whole construct, including its markers.
    public var range: NSRange
    public var markerRanges: [NSRange]
    public var children: [Inline]

    public init(kind: Kind, range: NSRange, markerRanges: [NSRange] = [], children: [Inline] = []) {
        self.kind = kind
        self.range = range
        self.markerRanges = markerRanges
        self.children = children
    }
}

/// Which syntax extensions are enabled. `gfm` is the default profile (PRD §8).
public struct Dialect: Sendable, Equatable {
    public var tables: Bool
    public var taskLists: Bool
    public var strikethrough: Bool
    public var bareAutolinks: Bool
    public var frontmatter: Bool

    public init(tables: Bool, taskLists: Bool, strikethrough: Bool, bareAutolinks: Bool, frontmatter: Bool) {
        self.tables = tables
        self.taskLists = taskLists
        self.strikethrough = strikethrough
        self.bareAutolinks = bareAutolinks
        self.frontmatter = frontmatter
    }

    public static let commonMark = Dialect(tables: false, taskLists: false, strikethrough: false, bareAutolinks: false, frontmatter: false)
    public static let gfm = Dialect(tables: true, taskLists: true, strikethrough: true, bareAutolinks: true, frontmatter: true)
}

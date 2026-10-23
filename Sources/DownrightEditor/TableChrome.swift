import AppKit
import MarkdownKit

/// Where a table sits on screen: its rows, its columns as scrolled, and its pinned first
/// column. Text view coordinates throughout.
public struct TableGeometry: Equatable {
    public var blockStart: Int
    /// The table's left edge as if unscrolled.
    public var left: CGFloat
    public var scroll: CGFloat
    /// The first column, drawn in place while the table is scrolled (0: none).
    public var pinnedWidth: CGFloat
    /// Width of the text column the table scrolls within.
    public var viewportWidth: CGFloat
    /// Column rules relative to `left`, unscrolled; `columns + 1` of them.
    public var boundaries: [CGFloat]
    /// Top of each row (`table.allRows`), then the bottom of the last one.
    public var rowEdges: [CGFloat]
    /// Whether the table is wider than the column (it has a scroll bar under it).
    public var wide: Bool

    public var columns: Int { max(0, boundaries.count - 1) }
    public var rows: Int { max(0, rowEdges.count - 1) }
    public var top: CGFloat { rowEdges.first ?? 0 }
    public var bottom: CGFloat { rowEdges.last ?? 0 }
    public var visibleMinX: CGFloat { left }
    public var visibleMaxX: CGFloat { left + min(viewportWidth, (boundaries.last ?? 0) - scroll) }
    /// Where the scrolled part of the table starts showing (after the pinned column).
    private var scrolledMinX: CGFloat { left + pinnedWidth }

    /// The x of column rule `k` as drawn (scrolled; the pinned column's own rules stay).
    public func edgeX(_ k: Int) -> CGFloat {
        guard k < boundaries.count else { return visibleMaxX }
        if pinnedWidth > 0, k <= 1 { return left + boundaries[k] }
        return left + boundaries[k] - scroll
    }

    /// Column rule `k` if it is on screen.
    public func visibleEdgeX(_ k: Int) -> CGFloat? {
        let x = edgeX(k)
        if pinnedWidth > 0, k <= 1 { return x }
        return x >= scrolledMinX - 0.5 && x <= visibleMaxX + 0.5 ? x : nil
    }

    /// The on-screen part of column `c`, or nil when it is scrolled out of view.
    public func columnSpan(_ c: Int) -> (minX: CGFloat, maxX: CGFloat)? {
        guard c >= 0, c < columns else { return nil }
        if pinnedWidth > 0, c == 0 { return (left, left + pinnedWidth) }
        let lo = max(edgeX(c), pinnedWidth > 0 ? scrolledMinX : left), hi = min(edgeX(c + 1), visibleMaxX)
        return hi - lo > 4 ? (lo, hi) : nil
    }

    public func rowSpan(_ r: Int) -> (minY: CGFloat, maxY: CGFloat)? {
        guard r >= 0, r < rows else { return nil }
        return (rowEdges[r], rowEdges[r + 1])
    }

}

extension EditorController {
    /// The table's on-screen geometry, or nil when it is not laid out as a table.
    public func tableGeometry(blockStart: Int) -> TableGeometry? {
        guard mode != .raw, let t = table(at: blockStart), let boundaries = engine.tableBoundaries(blockStart: blockStart) else { return nil }
        let inset = textView.textContainerInset
        var edges: [CGFloat] = []
        var bottom: CGFloat = 0
        var frameMinX: CGFloat?
        for row in t.allRows {
            guard let loc = contentStorage.location(contentStorage.documentRange.location, offsetBy: row.range.location) else { return nil }
            layoutManager.ensureLayout(for: NSTextRange(location: loc))
            guard let f = layoutManager.textLayoutFragment(for: loc) else { return nil }
            let frame = f.layoutFragmentFrame
            let decorated = f as? DecoratedLayoutFragment
            let top = inset.height + frame.minY
            edges.append(top)
            bottom = top + (decorated?.contentHeight ?? frame.height)
            if frameMinX == nil { frameMinX = frame.minX }
        }
        edges.append(bottom)
        let scroll = engine.tableScroll(blockStart: blockStart)
        // A scrolled row's frame starts left of its indent by the scroll (a caret rect
        // would be clamped to the container instead).
        guard let minX = frameMinX else { return nil }
        let leadingPipe = (t.header.separators.first?.length ?? 0) > 0
        let left = inset.width + minX + scroll - (leadingPipe ? 0 : DecorationEngine.cellGutter)
        return TableGeometry(blockStart: blockStart, left: left, scroll: scroll, pinnedWidth: engine.tablePinnedWidth(blockStart: blockStart),
                             viewportWidth: engine.columnWidth, boundaries: boundaries, rowEdges: edges,
                             wide: engine.tableScrollLimit(blockStart: blockStart) > 0)
    }

    /// A scrolled table whose pinned first column is under `point`. The pinned cells are a
    /// picture of the real ones, which are scrolled away: a click there scrolls the table
    /// home first, so it lands on the real cell in the same place.
    func pinnedTable(at point: NSPoint) -> Int? {
        guard let offset = characterIndex(at: point), let h = tableHit(at: offset) else { return nil }
        let start = h.block.range.location
        let pin = engine.tablePinnedWidth(blockStart: start)
        guard pin > 0, let g = tableGeometry(blockStart: start), point.x >= g.left, point.x <= g.left + pin else { return nil }
        return start
    }
}

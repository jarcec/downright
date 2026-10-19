import AppKit

/// A text container that lets a table scroll sideways on its own. For the lines of a
/// scrolled table it offers a line rectangle that starts left of the column by the
/// table's offset, so the row is laid out shifted: caret, selection and hit-testing
/// follow because the glyphs really are where they are drawn.
///
/// Overriding this hook at all takes TextKit 2 off the layout path that honours a
/// clipping line-break mode, so table rows (which must never wrap) get a rectangle as
/// wide as any row could be instead; their fragment clips the drawing to the column.
final class TableScrollingTextContainer: NSTextContainer {
    /// For the line holding the character at this (absolute) index: nil when it is not a
    /// table line, else the horizontal offset of its table (0 when unscrolled).
    var tableShift: (Int) -> CGFloat? = { _ in nil }
    /// Area at the top-right kept clear for a page float (`EditorController.pageFloatSize`):
    /// lines level with it end before it. Table rows ignore it — they never wrap — and pass
    /// under the float.
    var floatRect: CGRect?

    override func lineFragmentRect(forProposedRect proposedRect: CGRect, at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<CGRect>?) -> CGRect {
        var r = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex, writingDirection: baseWritingDirection, remaining: remainingRect)
        if let shift = tableShift(characterIndex) {
            r.origin.x -= shift
            r.size.width = 1e7
        } else if let f = floatRect, r.minY < f.maxY, r.maxY > f.minY, r.maxX > f.minX {
            r.size.width = max(0, f.minX - r.minX)
        }
        return r
    }
}

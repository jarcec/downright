import AppKit

/// The scroll bar under a table wider than the column: shows how much of the table is in
/// view and where, and scrolls that table alone — drag the knob, or click the track to
/// jump there. Always shown while the table overflows, so the overflow is visible.
final class TableScrollBar: NSView {
    var blockStart = 0
    /// How far the table is scrolled, of `limit`.
    var offset: CGFloat = 0 { didSet { if offset != oldValue { needsDisplay = true; updateAccessibility() } } }
    var limit: CGFloat = 0 { didSet { if limit != oldValue { needsDisplay = true; updateAccessibility() } } }
    var theme = Theme() { didSet { needsDisplay = true } }
    /// Asked to scroll the table at `blockStart` to an offset (clamped by the receiver).
    var onScroll: ((Int, CGFloat) -> Void)?

    private var hovering = false { didSet { if hovering != oldValue { needsDisplay = true } } }
    private var drag: (x: CGFloat, offset: CGFloat)?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.scrollBar)
        setAccessibilityOrientation(.horizontal)
        setAccessibilityLabel("Table scroll bar")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// The knob: as wide as the share of the table in view, placed by the offset.
    var knobRect: NSRect {
        let w = bounds.width
        let knob = min(w, max(28, w * w / (w + max(0, limit))))
        let x = limit > 0 ? (w - knob) * min(1, max(0, offset / limit)) : 0
        return NSRect(x: x, y: 0, width: knob, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        theme.rule.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        theme.secondaryColor.withAlphaComponent(hovering || drag != nil ? 0.7 : 0.4).setFill()
        NSBezierPath(roundedRect: knobRect, xRadius: radius, yRadius: radius).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let knob = knobRect
        if !knob.contains(p) {
            // A click on the track brings the knob's middle there, then drags from it.
            onScroll?(blockStart, offset(forKnobAt: p.x - knob.width / 2))
        }
        drag = (p.x, offset)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let travel = bounds.width - knobRect.width
        guard travel > 0 else { return }
        let x = convert(event.locationInWindow, from: nil).x
        onScroll?(blockStart, drag.offset + (x - drag.x) * limit / travel)
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        needsDisplay = true
    }

    private func offset(forKnobAt x: CGFloat) -> CGFloat {
        let travel = bounds.width - knobRect.width
        return travel > 0 ? max(0, min(limit, x / travel * limit)) : 0
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }

    private func updateAccessibility() {
        setAccessibilityValue(limit > 0 ? NSNumber(value: Double(offset / limit)) : 0)
    }
}

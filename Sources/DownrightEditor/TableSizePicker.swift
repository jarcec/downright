import AppKit

/// The grid Insert Table opens at the caret: point at (or arrow to) the size, click or
/// press Return to insert. Rows count the header.
final class TableSizePicker: NSView {
    private(set) var columns = 3
    private(set) var rows = 3
    var theme = Theme() { didSet { needsDisplay = true } }
    /// Called with (columns, rows) when a size is picked.
    var onPick: ((Int, Int) -> Void)?
    var onCancel: (() -> Void)?

    private let maxColumns = 8, maxRows = 8
    private let cell: CGFloat = 18, gap: CGFloat = 3, pad: CGFloat = 12, labelHeight: CGFloat = 22
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setFrameSize(NSSize(width: pad * 2 + CGFloat(maxColumns) * (cell + gap) - gap,
                            height: pad * 2 + CGFloat(maxRows) * (cell + gap) - gap + labelHeight))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func rect(column c: Int, row r: Int) -> NSRect {
        NSRect(x: pad + CGFloat(c) * (cell + gap), y: pad + CGFloat(r) * (cell + gap), width: cell, height: cell)
    }

    override func draw(_ dirtyRect: NSRect) {
        for r in 0..<maxRows {
            for c in 0..<maxColumns {
                let on = c < columns && r < rows
                let path = NSBezierPath(roundedRect: rect(column: c, row: r).insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                (on ? theme.markerColor.withAlphaComponent(r == 0 ? 0.32 : 0.2) : theme.backgroundColor).setFill()
                path.fill()
                (on ? theme.markerColor : theme.rule).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        let label = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.secondaryColor,
        ])
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - pad - size.height + 2))
    }

    var label: String {
        "\(columns) column\(columns == 1 ? "" : "s") × \(rows) row\(rows == 1 ? "" : "s")"
    }

    private func set(columns: Int, rows: Int) {
        let c = max(1, min(maxColumns, columns)), r = max(1, min(maxRows, rows))
        guard c != self.columns || r != self.rows else { return }
        self.columns = c
        self.rows = r
        needsDisplay = true
        updateAccessibility()
    }

    private func size(at p: NSPoint) -> (Int, Int)? {
        let c = Int(((p.x - pad) / (cell + gap)).rounded(.down)) + 1, r = Int(((p.y - pad) / (cell + gap)).rounded(.down)) + 1
        guard p.x >= pad - gap, p.y >= pad - gap, c >= 1, r >= 1, c <= maxColumns, r <= maxRows else { return nil }
        return (c, r)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        if let (c, r) = size(at: convert(event.locationInWindow, from: nil)) { set(columns: c, rows: r) }
    }

    override func mouseDown(with event: NSEvent) {
        if let (c, r) = size(at: convert(event.locationInWindow, from: nil)) { set(columns: c, rows: r); onPick?(columns, rows) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: set(columns: columns - 1, rows: rows)
        case 124: set(columns: columns + 1, rows: rows)
        case 125: set(columns: columns, rows: rows + 1)
        case 126: set(columns: columns, rows: rows - 1)
        case 36, 76, 49: onPick?(columns, rows)
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }

    private func updateAccessibility() {
        setAccessibilityLabel("Table size: \(label). Arrow keys change it, Return inserts.")
    }
}

import AppKit

/// The controls around the table the caret is in: a grip above each column and beside
/// each row (click to select it, drag to move it, ⌥-drag to copy it), a + where two
/// columns or rows meet (insert one there), and the "New row" strip underneath. Also
/// draws the selected row or column. Covers just the table and its margins (the visible
/// page while dragging) with bounds in text view coordinates, and only its controls take
/// the mouse; everything else falls through to the text.
final class TableChromeView: NSView {
    weak var textView: MarkdownTextView?
    private var controller: EditorController? { textView?.controller }

    /// The table shown, nil when the caret is not in one (then nothing is drawn).
    private(set) var geometry: TableGeometry?
    private var selection: EditorController.TableSelection?
    /// The caret's cell: its grips are tinted, to say which row and column it is in.
    private var caretCell: (row: Int, column: Int)?
    var theme = Theme() { didSet { needsDisplay = true } }

    enum Part: Equatable {
        case columnGrip(Int), rowGrip(Int)
        /// A + between columns or rows: the gap index (before column / row `k`).
        case columnGap(Int), rowGap(Int)
        case newRow
    }
    private(set) var hover: Part? { didSet { if hover != oldValue { needsDisplay = true } } }

    private struct Drag {
        var part: Part
        var start: NSPoint
        var point: NSPoint
        var active = false
        var gap: Int?
        var image: NSImage?
        /// Where the picked-up row or column was.
        var imageOrigin: NSPoint = .zero
        /// Where the picked-up row or column sat relative to the pointer.
        var grab: NSPoint = .zero
    }
    private var drag: Drag? { didSet { needsDisplay = true } }
    var isDragging: Bool { drag?.active == true }

    /// Height of the band above the header holding the column grips.
    static let stripHeight: CGFloat = 14
    /// Distance from the table's left edge to the row grips.
    static let gripInset: CGFloat = 14

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    /// Frame around the table, bounds matching the text view's coordinates, so every
    /// rect here is a text view rect.
    private func fitFrame() {
        guard let textView, let g = geometry else { return }
        var r = NSRect(x: g.left - Self.gripInset - 14, y: g.top - Self.stripHeight - 4,
                       width: g.visibleMaxX - g.left + Self.gripInset + 22, height: g.newRowRect.maxY + 4 - (g.top - Self.stripHeight - 4))
        if drag != nil { r = r.union(textView.visibleRect) }
        r = r.integral
        if frame != r { frame = r }
        if bounds.origin != r.origin { setBoundsOrigin(r.origin) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - State

    func update(geometry: TableGeometry?, selection: EditorController.TableSelection?, caretCell: (row: Int, column: Int)?) {
        let changed = geometry != self.geometry || selection != self.selection || caretCell?.row != self.caretCell?.row || caretCell?.column != self.caretCell?.column
        self.geometry = geometry
        self.selection = selection
        self.caretCell = caretCell
        if geometry == nil { hover = nil; if drag != nil { drag = nil } }
        fitFrame()
        if changed {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            rebuildToolTips()
        }
    }

    // MARK: - Where the controls are

    private func gripRect(_ part: Part, in g: TableGeometry) -> NSRect? {
        switch part {
        case .columnGrip(let c):
            guard let span = g.columnSpan(c) else { return nil }
            let mid = (span.minX + span.maxX) / 2
            return NSRect(x: mid - 14, y: g.top - Self.stripHeight, width: 28, height: Self.stripHeight - 1)
        case .rowGrip(let r):
            guard let span = g.rowSpan(r) else { return nil }
            return NSRect(x: g.left - Self.gripInset - 8, y: span.minY + 2, width: 16, height: span.maxY - span.minY - 4)
        case .columnGap(let k):
            guard let x = g.visibleEdgeX(k) else { return nil }
            return NSRect(x: x - 6, y: g.top - Self.stripHeight, width: 12, height: Self.stripHeight - 1)
        case .rowGap(let k):
            guard k >= 1, k <= g.rows else { return nil }
            return NSRect(x: g.left - Self.gripInset - 10, y: g.rowEdges[k] - 5, width: 20, height: 10)
        case .newRow:
            return g.newRowRect
        }
    }

    /// Every control, gaps first: a + sits between two grips and wins where they touch.
    private func parts(in g: TableGeometry) -> [Part] {
        (0...g.columns).map { Part.columnGap($0) } + (1...max(1, g.rows)).map { Part.rowGap($0) }
            + (0..<g.columns).map { Part.columnGrip($0) } + (0..<g.rows).map { Part.rowGrip($0) } + [.newRow]
    }

    func part(at point: NSPoint) -> Part? {
        guard let g = geometry else { return nil }
        return parts(in: g).first { gripRect($0, in: g)?.contains(point) == true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        if drag != nil { return self }
        return part(at: convert(point, from: superview)) != nil ? self : nil
    }

    override func resetCursorRects() {
        guard let g = geometry else { return }
        for p in parts(in: g) {
            guard let r = gripRect(p, in: g) else { continue }
            switch p {
            case .columnGap, .rowGap, .newRow: addCursorRect(r, cursor: .pointingHand)
            case .columnGrip, .rowGrip: addCursorRect(r, cursor: .openHand)
            }
        }
    }

    /// Tool tip owners are not retained by AppKit; these strings are.
    private var tips: [NSString] = []

    private func rebuildToolTips() {
        removeAllToolTips()
        tips.removeAll()
        guard let g = geometry else { return }
        for p in parts(in: g) {
            guard let r = gripRect(p, in: g) else { continue }
            let tip: String
            switch p {
            case .columnGrip: tip = "Select column · drag to move · ⌥-drag to copy"
            case .rowGrip(0): tip = "Select the header row"
            case .rowGrip: tip = "Select row · drag to move · ⌥-drag to copy"
            case .columnGap: tip = "Insert column"
            case .rowGap: tip = "Insert row"
            case .newRow: tip = "Add a row at the end"
            }
            let owner = tip as NSString
            tips.append(owner)
            addToolTip(r, owner: owner, userData: nil)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let g = geometry else { return }
        let marker = theme.markerColor

        // The selected row or column: tinted, outlined.
        if let sel = selection, sel.blockStart == g.blockStart, let r = selectionRect(sel, in: g) {
            marker.withAlphaComponent(0.13).setFill()
            r.fill(using: .sourceOver)
            marker.setStroke()
            let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 2, yRadius: 2)
            path.lineWidth = 1.5
            path.stroke()
        }

        // Grips.
        for c in 0..<g.columns {
            guard let span = g.columnSpan(c) else { continue }
            let mid = (span.minX + span.maxX) / 2
            let selected = selection == .column(blockStart: g.blockStart, index: c)
            let w: CGFloat = selected ? 30 : 22
            gripColor(selected: selected, hovered: hover == .columnGrip(c), caret: caretCell?.column == c).setFill()
            NSBezierPath(roundedRect: NSRect(x: mid - w / 2, y: g.top - 9, width: w, height: 4), xRadius: 2, yRadius: 2).fill()
        }
        for r in 0..<g.rows {
            guard let span = g.rowSpan(r) else { continue }
            let mid = (span.minY + span.maxY) / 2
            let selected = selection == .row(blockStart: g.blockStart, index: r)
            let h: CGFloat = selected ? 24 : 18
            gripColor(selected: selected, hovered: hover == .rowGrip(r), caret: caretCell?.row == r).setFill()
            NSBezierPath(roundedRect: NSRect(x: g.left - Self.gripInset - 2, y: mid - h / 2, width: 4, height: h), xRadius: 2, yRadius: 2).fill()
        }

        // The "New row" strip.
        let strip = g.newRowRect
        if strip.width > 40 {
            let hovered = hover == .newRow
            let path = NSBezierPath(roundedRect: strip.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            path.lineWidth = 1
            path.setLineDash([3, 3], count: 2, phase: 0)
            (hovered ? marker.withAlphaComponent(0.6) : theme.rule).setStroke()
            path.stroke()
            if hovered { marker.withAlphaComponent(0.06).setFill(); path.fill() }
            let color = hovered ? marker : theme.secondaryColor
            drawPlus(center: NSPoint(x: strip.minX + 15, y: strip.midY), size: 9, color: color, width: 1.4)
            let label = NSAttributedString(string: "New row", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color])
            label.draw(at: NSPoint(x: strip.minX + 26, y: strip.midY - label.size().height / 2))
        }

        // Insert here / drop here: a line through the table at the gap, with its +.
        if let drag, drag.active, let gap = drag.gap {
            drawGapLine(drag.part.isRow ? .rowGap(gap) : .columnGap(gap), in: g, withButton: false)
        } else if let hover, case .columnGap = hover {
            drawGapLine(hover, in: g, withButton: true)
        } else if let hover, case .rowGap = hover {
            drawGapLine(hover, in: g, withButton: true)
        }

        // The row or column being dragged: faded where it was, and under the pointer.
        if let drag, drag.active {
            let source: EditorController.TableSelection?
            switch drag.part {
            case .rowGrip(let r): source = .row(blockStart: g.blockStart, index: r)
            case .columnGrip(let c): source = .column(blockStart: g.blockStart, index: c)
            default: source = nil
            }
            if let source, let r = selectionRect(source, in: g) {
                theme.backgroundColor.withAlphaComponent(0.65).setFill()
                r.fill(using: .sourceOver)
            }
        }
        if let drag, drag.active, let image = drag.image {
            let origin = NSPoint(x: drag.part.isRow ? drag.imageOrigin.x : drag.point.x - drag.grab.x,
                                 y: drag.part.isRow ? drag.point.y - drag.grab.y : drag.imageOrigin.y)
            let rect = NSRect(origin: origin, size: image.size)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -5)
            shadow.set()
            theme.backgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            NSGraphicsContext.restoreGraphicsState()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.92, respectFlipped: true, hints: nil)
            marker.withAlphaComponent(0.5).setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3).stroke()
        }
    }

    private func gripColor(selected: Bool, hovered: Bool, caret: Bool) -> NSColor {
        if selected { return theme.markerColor }
        if hovered { return theme.secondaryColor.withAlphaComponent(0.75) }
        if caret { return theme.markerColor.withAlphaComponent(0.5) }
        return theme.secondaryColor.withAlphaComponent(0.3)
    }

    func selectionRect(_ sel: EditorController.TableSelection, in g: TableGeometry) -> NSRect? {
        switch sel {
        case .row(_, let r):
            guard let span = g.rowSpan(r) else { return nil }
            return NSRect(x: g.visibleMinX, y: span.minY, width: g.visibleMaxX - g.visibleMinX, height: span.maxY - span.minY)
        case .column(_, let c):
            guard let span = g.columnSpan(c) else { return nil }
            return NSRect(x: span.minX, y: g.top, width: span.maxX - span.minX, height: g.bottom - g.top)
        }
    }

    private func drawGapLine(_ part: Part, in g: TableGeometry, withButton: Bool) {
        let marker = theme.markerColor
        marker.setFill()
        let center: NSPoint
        switch part {
        case .columnGap(let k):
            let x = g.edgeX(k)
            NSRect(x: x - 1, y: g.top - 2, width: 2, height: g.bottom - g.top + 4).fill()
            center = NSPoint(x: x, y: g.top - 7)
        case .rowGap(let k):
            let y = g.rowEdges[min(k, g.rows)]
            NSRect(x: g.visibleMinX - 4, y: y - 1, width: g.visibleMaxX - g.visibleMinX + 8, height: 2).fill()
            center = NSPoint(x: g.left - Self.gripInset, y: y)
        default:
            return
        }
        let circle = NSBezierPath(ovalIn: NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16))
        if withButton {
            theme.backgroundColor.setStroke()
            circle.lineWidth = 3
            circle.stroke()
            marker.setFill()
            circle.fill()
            drawPlus(center: center, size: 8, color: theme.backgroundColor, width: 1.6)
        } else {
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
            theme.backgroundColor.setFill(); dot.fill()
            marker.setStroke(); dot.lineWidth = 2; dot.stroke()
        }
    }

    private func drawPlus(center: NSPoint, size: CGFloat, color: NSColor, width: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: center.x - size / 2, y: center.y)); p.line(to: NSPoint(x: center.x + size / 2, y: center.y))
        p.move(to: NSPoint(x: center.x, y: center.y - size / 2)); p.line(to: NSPoint(x: center.x, y: center.y + size / 2))
        p.lineWidth = width
        p.lineCapStyle = .round
        color.setStroke()
        p.stroke()
    }

    // MARK: - Mouse

    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        hover = part(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) { hover = nil }

    /// Hover as the text view tracks it (this view's own tracking only sees the controls'
    /// edges when the text view takes the move first).
    func pointerMoved(to point: NSPoint?) { hover = point.flatMap { part(at: $0) } }

    override func mouseDown(with event: NSEvent) {
        guard let controller, let g = geometry else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard let part = part(at: p) else { return }
        window?.makeFirstResponder(textView)
        let start = g.blockStart
        switch part {
        case .columnGap(let k):
            let n = g.columns
            controller.clearTableSelection()
            if k < n { controller.performTableOperation(.insertColumnLeft, on: .init(blockStart: start, row: 0, column: k)) }
            else { controller.performTableOperation(.insertColumnRight, on: .init(blockStart: start, row: 0, column: n - 1)) }
            hover = nil
        case .rowGap(let k):
            controller.clearTableSelection()
            if k < g.rows { controller.performTableOperation(.insertRowAbove, on: .init(blockStart: start, row: k, column: 0)) }
            else { controller.performTableOperation(.insertRowBelow, on: .init(blockStart: start, row: g.rows - 1, column: 0)) }
            hover = nil
        case .newRow:
            controller.clearTableSelection()
            controller.performTableOperation(.insertRowBelow, on: .init(blockStart: start, row: g.rows - 1, column: 0))
        case .columnGrip, .rowGrip:
            drag = Drag(part: part, start: p, point: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag, let g = geometry else { return }
        let p = convert(event.locationInWindow, from: nil)
        d.point = p
        if !d.active, hypot(p.x - d.start.x, p.y - d.start.y) > 4, d.part != .rowGrip(0) {
            d.active = true
            if let (image, origin) = snapshot(of: d.part, in: g) {
                d.image = image
                d.imageOrigin = origin
                d.grab = NSPoint(x: d.start.x - origin.x, y: d.start.y - origin.y)
            }
            NSCursor.closedHand.set()
        }
        if d.active {
            d.gap = gap(for: d.part, at: p, in: g)
            if d.part.isRow { textView?.autoscroll(with: event) }
        }
        drag = d
        fitFrame()
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = drag, let controller, let g = geometry else { drag = nil; return }
        drag = nil
        fitFrame()
        let start = g.blockStart
        switch d.part {
        case .columnGrip(let c):
            if d.active, let k = d.gap {
                controller.selectTableColumn(blockStart: start, index: c)
                controller.performOnTableSelection(event.modifierFlags.contains(.option) ? .copyColumn(to: k) : .moveColumn(to: k))
            } else if !d.active {
                controller.selectTableColumn(blockStart: start, index: c)
            }
        case .rowGrip(let r):
            if d.active, let k = d.gap {
                controller.selectTableRow(blockStart: start, index: r)
                controller.performOnTableSelection(event.modifierFlags.contains(.option) ? .copyRow(to: k) : .moveRow(to: k))
            } else if !d.active {
                controller.selectTableRow(blockStart: start, index: r)
            }
        default:
            break
        }
        NSCursor.arrow.set()
    }

    /// Esc while dragging: put it back.
    func cancelDrag() -> Bool {
        guard drag != nil else { return false }
        drag = nil
        NSCursor.arrow.set()
        return true
    }

    /// The gap nearest the pointer that would actually move something (dropping a row
    /// where it already is does nothing, so that gap is not offered).
    private func gap(for part: Part, at p: NSPoint, in g: TableGeometry) -> Int? {
        switch part {
        case .rowGrip(let r):
            let candidates = (1...g.rows).filter { $0 != r && $0 != r + 1 }
            return candidates.min { abs(g.rowEdges[$0] - p.y) < abs(g.rowEdges[$1] - p.y) }
        case .columnGrip(let c):
            let candidates = (0...g.columns).filter { $0 != c && $0 != c + 1 }
            return candidates.min { abs(g.edgeX($0) - p.x) < abs(g.edgeX($1) - p.x) }
        default:
            return nil
        }
    }

    /// A picture of the row or column as drawn, without the controls on top.
    private func snapshot(of part: Part, in g: TableGeometry) -> (NSImage, NSPoint)? {
        guard let textView else { return nil }
        let rect: NSRect
        switch part {
        case .rowGrip(let r):
            guard let span = g.rowSpan(r) else { return nil }
            rect = NSRect(x: g.visibleMinX, y: span.minY, width: g.visibleMaxX - g.visibleMinX, height: span.maxY - span.minY)
        case .columnGrip(let c):
            guard let span = g.columnSpan(c) else { return nil }
            rect = NSRect(x: span.minX, y: g.top, width: span.maxX - span.minX, height: g.bottom - g.top)
        default:
            return nil
        }
        let wasHidden = isHidden
        isHidden = true
        defer { isHidden = wasHidden }
        guard let rep = textView.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        textView.cacheDisplay(in: rect, to: rep)
        let image = NSImage(size: rect.size)
        image.addRepresentation(rep)
        return (image, rect.origin)
    }
}

extension TableChromeView.Part {
    var isRow: Bool {
        switch self {
        case .rowGrip, .rowGap: return true
        default: return false
        }
    }
}

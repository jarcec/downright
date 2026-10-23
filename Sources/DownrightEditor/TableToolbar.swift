import AppKit
import MarkdownKit

/// The small toolbar over a selected row or column: inserts, moves, alignment and sort
/// (columns), duplicate (rows), delete. Each button's tool tip names its shortcut.
final class TableToolbar: NSView {
    enum Kind { case row, column }

    weak var controller: EditorController?
    private(set) var kind: Kind = .column
    private var buttons: [(NSButton, EditorController.TableOperation)] = []
    private let stack = NSStackView()
    var theme = Theme() { didSet { applyTheme() } }

    private static let buttonSize = NSSize(width: 28, height: 26)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 10
            s.shadowOffset = NSSize(width: 0, height: -3)
            s.shadowColor = NSColor.black.withAlphaComponent(0.18)
            return s
        }()
        stack.orientation = .horizontal
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.toolbar)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Lay the buttons out for a row or a column and refresh their states.
    func configure(for kind: Kind) {
        if kind != self.kind || buttons.isEmpty {
            self.kind = kind
            rebuild()
        }
        refresh()
    }

    private typealias Item = (symbol: String, op: EditorController.TableOperation, tip: String)

    private func items(for kind: Kind) -> [[Item]] {
        switch kind {
        case .column:
            return [
                [("insertColumnLeft", .insertColumnLeft, "Insert column left  ⌥⌘←"), ("insertColumnRight", .insertColumnRight, "Insert column right  ⌥⌘→")],
                [("text.alignleft", .align(.left), "Align left"), ("text.aligncenter", .align(.center), "Align center"), ("text.alignright", .align(.right), "Align right")],
                [("arrow.left", .moveColumnLeft, "Move column left  ⌃⌥⌘←"), ("arrow.right", .moveColumnRight, "Move column right  ⌃⌥⌘→")],
                [("arrow.up.arrow.down", .sort(ascending: true), "Sort rows by this column"), ("trash", .deleteColumn, "Delete column  ⌫")],
            ]
        case .row:
            return [
                [("insertRowAbove", .insertRowAbove, "Insert row above  ⌥⌘↑"), ("insertRowBelow", .insertRowBelow, "Insert row below  ⌥⌘↓")],
                [("arrow.up", .moveRowUp, "Move row up  ⌃⌥⌘↑"), ("arrow.down", .moveRowDown, "Move row down  ⌃⌥⌘↓")],
                [("plus.square.on.square", .duplicateRow, "Duplicate row"), ("trash", .deleteRow, "Delete row  ⌫")],
            ]
        }
    }

    private func rebuild() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        buttons.removeAll()
        let groups = items(for: kind)
        for (gi, group) in groups.enumerated() {
            if gi > 0 {
                let sep = NSBox()
                sep.boxType = .custom
                sep.borderWidth = 0
                sep.fillColor = theme.rule
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
                sep.heightAnchor.constraint(equalToConstant: 16).isActive = true
                stack.addArrangedSubview(sep)
                stack.setCustomSpacing(4, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
                stack.setCustomSpacing(4, after: sep)
            }
            for item in group {
                let b = NSButton(image: Self.icon(item.symbol, label: item.tip), target: self, action: #selector(press(_:)))
                b.isBordered = false
                b.imagePosition = .imageOnly
                b.toolTip = item.tip
                b.setAccessibilityLabel(item.tip.components(separatedBy: "  ").first)
                b.wantsLayer = true
                b.layer?.cornerRadius = 5
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: Self.buttonSize.width).isActive = true
                b.heightAnchor.constraint(equalToConstant: Self.buttonSize.height).isActive = true
                stack.addArrangedSubview(b)
                buttons.append((b, item.op))
            }
        }
        applyTheme()
        setFrameSize(fittingSize)
    }

    /// Enabled states, the column's alignment, and which way Sort will go.
    func refresh() {
        guard let controller else { return }
        var alignment: TableAlignment?
        var sortedAscending: Bool?
        if case .column(let b, let c)? = controller.tableSelection {
            alignment = controller.tableColumnAlignment(blockStart: b, column: c)
            sortedAscending = controller.tableSortOrder(blockStart: b, column: c)
        }
        for (i, (button, op)) in buttons.enumerated() {
            var op = op
            if case .sort = op {
                // Sorted A→Z already: the next press sorts Z→A.
                op = .sort(ascending: sortedAscending != true)
                buttons[i].1 = op
                button.toolTip = sortedAscending == true ? "Sort rows by this column, Z to A" : "Sort rows by this column, A to Z"
            }
            button.isEnabled = controller.canPerformOnTableSelection(op)
            var on = false
            if case .align(let a) = op { on = alignment == a }
            button.state = on ? .on : .off
            button.layer?.backgroundColor = on ? theme.markerColor.withAlphaComponent(0.16).cgColor : nil
            if case .deleteRow = op { button.contentTintColor = theme.color(for: .removed) }
            else if case .deleteColumn = op { button.contentTintColor = theme.color(for: .removed) }
            else { button.contentTintColor = on ? theme.markerColor : theme.textColor }
        }
    }

    private func applyTheme() {
        layer?.backgroundColor = theme.backgroundColor.blended(withFraction: 0.35, of: .white)?.cgColor ?? theme.backgroundColor.cgColor
        if theme.backgroundColor.brightnessComponentSafe < 0.4 {
            layer?.backgroundColor = theme.codeBlockBackground.cgColor
        }
        layer?.borderColor = theme.rule.cgColor
        for v in stack.arrangedSubviews { (v as? NSBox)?.fillColor = theme.rule }
        refresh()
    }

    @objc private func press(_ sender: NSButton) {
        guard let controller, let op = buttons.first(where: { $0.0 === sender })?.1 else { return }
        // Pressing the alignment the column already has takes it off again.
        if case .align(let a) = op, case .column(let b, let c)? = controller.tableSelection,
           controller.tableColumnAlignment(blockStart: b, column: c) == a {
            controller.performOnTableSelection(.align(.none))
        } else {
            controller.performOnTableSelection(op)
        }
        controller.textView.window?.makeFirstResponder(controller.textView)
    }

    /// Buttons for tests.
    func button(for op: EditorController.TableOperation) -> NSButton? {
        buttons.first { b, o in
            if case .sort = o, case .sort = op { return true }
            return o == op
        }?.0
    }

    // MARK: - Icons

    /// SF Symbols, plus four drawn here: a column or row with a + beside it.
    private static func icon(_ name: String, label: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(config) { return image }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            let bar = NSBezierPath(), plus = NSBezierPath()
            switch name {
            case "insertColumnLeft":
                bar.appendRoundedRect(NSRect(x: 9.5, y: 3, width: 5.5, height: 12), xRadius: 1, yRadius: 1)
                plus.move(to: NSPoint(x: 2.5, y: 9)); plus.line(to: NSPoint(x: 7, y: 9))
                plus.move(to: NSPoint(x: 4.75, y: 6.75)); plus.line(to: NSPoint(x: 4.75, y: 11.25))
            case "insertColumnRight":
                bar.appendRoundedRect(NSRect(x: 3, y: 3, width: 5.5, height: 12), xRadius: 1, yRadius: 1)
                plus.move(to: NSPoint(x: 11, y: 9)); plus.line(to: NSPoint(x: 15.5, y: 9))
                plus.move(to: NSPoint(x: 13.25, y: 6.75)); plus.line(to: NSPoint(x: 13.25, y: 11.25))
            case "insertRowAbove":
                bar.appendRoundedRect(NSRect(x: 3, y: 9.5, width: 12, height: 5.5), xRadius: 1, yRadius: 1)
                plus.move(to: NSPoint(x: 6.75, y: 4.75)); plus.line(to: NSPoint(x: 11.25, y: 4.75))
                plus.move(to: NSPoint(x: 9, y: 2.5)); plus.line(to: NSPoint(x: 9, y: 7))
            default: // insertRowBelow
                bar.appendRoundedRect(NSRect(x: 3, y: 3, width: 12, height: 5.5), xRadius: 1, yRadius: 1)
                plus.move(to: NSPoint(x: 6.75, y: 13.25)); plus.line(to: NSPoint(x: 11.25, y: 13.25))
                plus.move(to: NSPoint(x: 9, y: 11)); plus.line(to: NSPoint(x: 9, y: 15.5))
            }
            for p in [bar, plus] { p.lineWidth = 1.4; p.lineCapStyle = .round; p.stroke() }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = label
        return image
    }
}

private extension NSColor {
    var brightnessComponentSafe: CGFloat { usingColorSpace(.sRGB)?.brightnessComponent ?? 1 }
}

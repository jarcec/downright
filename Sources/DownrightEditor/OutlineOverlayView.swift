import AppKit

/// Compact floating outline of the document's headings. Click to jump; the heading
/// containing the caret is highlighted.
@MainActor
public final class OutlineOverlayView: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    public var onSelect: ((Int) -> Void)?
    /// Called when the user collapses or expands the panel, so the host can persist it.
    public var onCollapsedChange: ((Bool) -> Void)?
    public var maxHeight: CGFloat = 360 { didSet { updateHeight() } }

    /// Collapsed shows only the header pill; a click expands it again.
    public var isCollapsed = false {
        didSet { guard isCollapsed != oldValue else { return }; applyCollapsed() }
    }

    private var headings: [EditorController.Heading] = []
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let header = NSButton()
    private var heightConstraint: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!
    private let rowHeight: CGFloat = 20
    private let headerHeight: CGFloat = 24
    private let expandedWidth: CGFloat = 230
    private let collapsedWidth: CGFloat = 96
    private var suppressSelection = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.style = .plain
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.focusRingType = .none
        table.refusesFirstResponder = true

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // Header: the whole row is a button that toggles collapse.
        header.isBordered = false
        header.bezelStyle = .inline
        header.imagePosition = .imageTrailing
        header.alignment = .left
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.contentTintColor = .secondaryLabelColor
        header.target = self
        header.action = #selector(toggleCollapsed(_:))
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setButtonType(.momentaryChange)
        header.focusRingType = .none
        header.toolTip = "Collapse or expand the outline"

        addSubview(header)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: headerHeight - 4),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        heightConstraint = heightAnchor.constraint(equalToConstant: 40)
        heightConstraint.isActive = true
        widthConstraint = widthAnchor.constraint(equalToConstant: expandedWidth)
        widthConstraint.isActive = true
        applyCollapsed()
    }

    @objc private func toggleCollapsed(_ sender: Any?) {
        isCollapsed.toggle()
        onCollapsedChange?(isCollapsed)
    }

    private func applyCollapsed() {
        scroll.isHidden = isCollapsed
        header.title = isCollapsed ? "Outline" : "Outline"
        let symbol = isCollapsed ? "chevron.down" : "chevron.up"
        header.image = NSImage(systemSymbolName: symbol, accessibilityDescription: isCollapsed ? "Expand" : "Collapse")
        header.image?.isTemplate = true
        widthConstraint.constant = isCollapsed ? collapsedWidth : expandedWidth
        updateHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Data

    public func reload(_ headings: [EditorController.Heading]) {
        guard headings != self.headings else { return }
        self.headings = headings
        isHidden = headings.isEmpty
        table.reloadData()
        updateHeight()
    }

    /// Highlight the last heading at or before `offset`.
    public func highlightHeading(containing offset: Int) {
        guard let idx = headings.lastIndex(where: { $0.offset <= offset }) else {
            suppressSelection = true; table.deselectAll(nil); suppressSelection = false
            return
        }
        if table.selectedRow != idx {
            suppressSelection = true
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            table.scrollRowToVisible(idx)
            suppressSelection = false
        }
    }

    private func updateHeight() {
        if isCollapsed { heightConstraint.constant = headerHeight; return }
        let h = min(maxHeight, CGFloat(headings.count) * rowHeight + headerHeight + 8)
        heightConstraint.constant = max(h, headerHeight + 8)
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < headings.count else { return }
        onSelect?(headings[row].offset)
    }

    // MARK: - NSTableViewDataSource / Delegate

    public func numberOfRows(in tableView: NSTableView) -> Int { headings.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let h = headings[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -10),
            ])
            return c
        }()
        // Re-pin leading for the indent
        if let tf = cell.textField {
            for con in cell.constraints where con.firstAnchor == tf.leadingAnchor { cell.removeConstraint(con) }
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12 + CGFloat(max(0, h.level - 1)) * 10).isActive = true
            tf.stringValue = h.title.isEmpty ? "(untitled)" : h.title
            tf.font = h.level == 1 ? .systemFont(ofSize: 11.5, weight: .semibold) : .systemFont(ofSize: 11, weight: h.level == 2 ? .medium : .regular)
            tf.textColor = h.level <= 2 ? .labelColor : .secondaryLabelColor
        }
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        // Selection is driven by the caret; clicks go through rowClicked.
    }
}

import AppKit

/// Compact outline of the document's headings. Click to jump; the heading containing the
/// caret is highlighted. It either floats over the text, translucent until hovered, or
/// sits on the page with the text wrapping around it (`EditorController.pageFloatSize`).
@MainActor
public final class OutlineOverlayView: NSVisualEffectView, NSTableViewDataSource, NSTableViewDelegate {
    public var onSelect: ((Int) -> Void)?
    /// The panel's current size, which the host keeps clear when it sits on the page.
    public var panelSize: CGSize { CGSize(width: widthConstraint.constant, height: heightConstraint.constant) }
    /// Called when `panelSize` changes: collapsed or expanded, headings added or removed.
    public var onSizeChange: (() -> Void)?
    /// The header's mode button, which moves the outline between floating over the text
    /// and sitting on the page: nil hides it, otherwise whether it is set to the page.
    public var onPage: Bool? { didSet { applyModeButton() } }
    /// Called when the mode button is clicked; the host switches the mode and sets `onPage`.
    public var onToggleMode: (() -> Void)?
    /// Over the text the panel is translucent until hovered, so the text shows through;
    /// on the page nothing is under it, and it is solid.
    public var floatsOverText = true { didSet { if floatsOverText != oldValue { alphaValue = restingAlphaValue } } }
    /// Colours follow the editor's theme, so the panel matches the page it floats over.
    public var theme = Theme() { didSet { applyTheme() } }
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
    let modeButton = NSButton()
    private var heightConstraint: NSLayoutConstraint!
    private var widthConstraint: NSLayoutConstraint!
    private let rowHeight: CGFloat = 20
    private let headerHeight: CGFloat = 24
    private let expandedWidth: CGFloat = 230
    private let collapsedWidth: CGFloat = 96
    private var suppressSelection = false

    /// Resting opacity while floating over the text; it becomes solid under the pointer.
    public var restingAlpha: CGFloat = 0.45
    private var restingAlphaValue: CGFloat { floatsOverText ? restingAlpha : 1 }
    private var hoverTracking: NSTrackingArea?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = theme.rule.cgColor
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
        header.contentTintColor = theme.secondaryColor
        header.target = self
        header.action = #selector(toggleCollapsed(_:))
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setButtonType(.momentaryChange)
        header.focusRingType = .none
        header.toolTip = "Collapse or expand the outline"

        modeButton.isBordered = false
        modeButton.bezelStyle = .inline
        modeButton.imagePosition = .imageOnly
        modeButton.contentTintColor = theme.secondaryColor
        modeButton.target = self
        modeButton.action = #selector(toggleMode(_:))
        modeButton.translatesAutoresizingMaskIntoConstraints = false
        modeButton.setButtonType(.momentaryChange)
        modeButton.focusRingType = .none

        addSubview(header)
        addSubview(modeButton)
        addSubview(scroll)
        headerTrailing = header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        headerBesideMode = header.trailingAnchor.constraint(equalTo: modeButton.leadingAnchor, constant: -6)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            header.heightAnchor.constraint(equalToConstant: headerHeight - 4),
            modeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            modeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            modeButton.widthAnchor.constraint(equalToConstant: 16),
            modeButton.heightAnchor.constraint(equalToConstant: headerHeight - 4),
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

    private var headerTrailing: NSLayoutConstraint!
    private var headerBesideMode: NSLayoutConstraint!

    @objc private func toggleMode(_ sender: Any?) { onToggleMode?() }

    /// Shown while expanded (the collapsed pill has no room). A pin: filled while the
    /// outline is pinned to the window over the text, outlined while it is on the page.
    private func applyModeButton() {
        let shown = onPage != nil && !isCollapsed
        modeButton.isHidden = !shown
        headerBesideMode.isActive = shown
        headerTrailing.isActive = !shown
        guard let onPage else { return }
        let (symbol, tip) = onPage
            ? ("pin", "On the page — click to pin the outline to the window, over the text")
            : ("pin.fill", "Pinned over the text — click to put the outline on the page, with the text wrapping around it")
        modeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        modeButton.image?.isTemplate = true
        modeButton.toolTip = tip
    }

    // MARK: - Hover: translucent at rest, solid under the pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverTracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        hoverTracking = t
    }

    public override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setSolid(true)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setSolid(false)
    }

    /// Headings behave like links: pointing hand over the rows, arrow over the header.
    public override func cursorUpdate(with event: NSEvent) { setCursor(for: event) }
    public override func mouseMoved(with event: NSEvent) { setCursor(for: event) }

    private func setCursor(for event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !isCollapsed, scroll.frame.contains(p), table.row(at: table.convert(p, from: self)) >= 0 {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func setSolid(_ solid: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = solid ? 1 : restingAlphaValue
        }
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
        alphaValue = restingAlphaValue
        if headerTrailing != nil { applyModeButton() }
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

    private var reportedSize: CGSize?

    private func updateHeight() {
        if isCollapsed {
            heightConstraint.constant = headerHeight
        } else {
            let h = min(maxHeight, CGFloat(headings.count) * rowHeight + headerHeight + 8)
            heightConstraint.constant = max(h, headerHeight + 8)
        }
        guard heightConstraint != nil, widthConstraint != nil, panelSize != reportedSize else { return }
        reportedSize = panelSize
        onSizeChange?()
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
            tf.textColor = h.level <= 2 ? theme.textColor : theme.secondaryColor
        }
        return cell
    }

    private func applyTheme() {
        layer?.borderColor = theme.rule.cgColor
        header.contentTintColor = theme.secondaryColor
        modeButton.contentTintColor = theme.secondaryColor
        table.reloadData()
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        // Selection is driven by the caret; clicks go through rowClicked.
    }
}

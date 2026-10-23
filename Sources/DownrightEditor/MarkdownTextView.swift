import AppKit
import MarkdownKit

/// The editing surface. Plain-text NSTextView on TextKit 2 with Markdown-aware
/// keyboard behaviour; rendering lives in the content-storage delegate.
@MainActor
public final class MarkdownTextView: NSTextView {
    weak var controller: EditorController?
    /// Modal editing layer; disabled unless the host turns it on.
    public let vim = VimEngine()

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, tableChrome.cancelDrag() { return }
        if handleTableSelectionKey(event) { return }
        if vim.handle(event) { return }
        super.keyDown(with: event)
    }

    // MARK: - Block cursor in vim normal/command mode

    // macOS 14+ draws the insertion point with NSTextInsertionIndicator, so
    // drawInsertionPoint(in:color:turnedOn:) is never called. The block is an overlay
    // view over the character under the caret; the thin caret is hidden meanwhile.
    private lazy var blockCursor: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 1.5
        v.isHidden = true
        addSubview(v)
        return v
    }()

    func vimModeDidChange() {
        updateInsertionPointColor()
        updateBlockCursor()
    }

    /// The caret is hidden while vim draws its own block cursor.
    func updateInsertionPointColor() {
        let hidden = (vim.isEnabled && vim.mode != .insert) || controller?.tableSelection != nil
        insertionPointColor = hidden ? .clear : (controller?.theme.textColor ?? .textColor)
    }

    func modeDidChange() {
        controller?.clearTableSelection()
        updateTableScrollBars()
    }

    /// The container does not track the view; size it to the new width minus the insets.
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller?.applyContainerWidth()
    }

    public func updateBlockCursor() {
        guard vim.isEnabled, vim.mode != .insert, selectedRange().length == 0, let controller,
              let caret = controller.caretRect(at: selectedRange().location) else {
            blockCursor.isHidden = true
            return
        }
        var width: CGFloat = font.map { ("m" as NSString).size(withAttributes: [.font: $0]).width * 0.55 } ?? 8
        if let w = controller.characterWidth(at: selectedRange().location), w > 0.5 { width = w }
        blockCursor.frame = NSRect(x: caret.minX, y: caret.minY, width: width, height: caret.height)
        blockCursor.layer?.backgroundColor = controller.theme.vimCursorColor.cgColor
        blockCursor.isHidden = false
    }

    public override func layout() {
        super.layout()
        updateSelectionOverlay()
        updateBlockCursor()
        updateTableScrollBars()
    }

    // MARK: - Table scroll bars

    /// One per wide table near the visible area; spares are kept hidden for reuse.
    private var tableScrollBars: [TableScrollBar] = []

    /// Place a scroll bar under each wide table on screen and hide the rest. Runs on
    /// layout, scrolling, and whenever the controller lays tables out again.
    public func updateTableScrollBars() {
        let spots = controller?.tableScrollBarSpots() ?? []
        while tableScrollBars.count < spots.count {
            let bar = TableScrollBar(frame: .zero)
            bar.onScroll = { [weak self] start, offset in self?.controller?.scrollTable(blockStart: start, to: offset) }
            addSubview(bar)
            tableScrollBars.append(bar)
        }
        for (i, bar) in tableScrollBars.enumerated() {
            guard i < spots.count else { bar.isHidden = true; continue }
            let spot = spots[i]
            if let theme = controller?.theme { bar.theme = theme }
            bar.frame = spot.frame
            bar.blockStart = spot.blockStart
            bar.limit = spot.limit
            bar.offset = spot.offset
            bar.isHidden = false
        }
        updateTableChrome()
        if !spots.isEmpty { updateSelectionOverlay() }
    }

    // MARK: - Table controls (grips, inserts, selection, toolbar)

    lazy var tableChrome: TableChromeView = {
        let v = TableChromeView(frame: .zero)
        v.textView = self
        return v
    }()

    lazy var tableToolbar: TableToolbar = {
        let v = TableToolbar(frame: .zero)
        v.controller = controller
        return v
    }()

    /// Show the controls for the caret's table (none outside one, or outside Live), and
    /// the toolbar over a selected row or column.
    func updateTableChrome() {
        guard let controller else { return }
        if tableChrome.superview !== self { addSubview(tableChrome) }
        if tableToolbar.superview !== self { addSubview(tableToolbar) }
        let start = controller.activeTableStart
        let geometry = start.flatMap { controller.tableGeometry(blockStart: $0) }
        var caretCell: (row: Int, column: Int)?
        if let h = controller.tableHit(at: selectedRange().location) { caretCell = (h.rowIndex, h.cellIndex ?? -1) }
        if controller.tableSelection.map({ $0.blockStart != start }) == true { controller.tableSelection = nil }
        tableChrome.theme = controller.theme
        tableChrome.update(geometry: geometry, selection: controller.tableSelection, caretCell: caretCell)
        tableChrome.isHidden = geometry == nil
        placeTableToolbar(geometry)
    }

    private func placeTableToolbar(_ geometry: TableGeometry?) {
        guard let controller, let g = geometry, let sel = controller.tableSelection, sel.blockStart == g.blockStart,
              let rect = tableChrome.selectionRect(sel, in: g) else {
            tableToolbar.isHidden = true
            return
        }
        tableToolbar.controller = controller
        tableToolbar.theme = controller.theme
        let aboveStrip = g.top - TableChromeView.stripHeight - 6
        let size: NSSize
        var origin: NSPoint
        switch sel {
        case .column:
            tableToolbar.configure(for: .column)
            size = tableToolbar.fittingSize
            origin = NSPoint(x: rect.midX - size.width / 2, y: aboveStrip - size.height)
        case .row(_, let r):
            tableToolbar.configure(for: .row)
            size = tableToolbar.fittingSize
            if g.visibleMaxX + 12 + size.width <= visibleRect.maxX - 6 {
                // Beside the row, past the table's end, when the page has room there.
                origin = NSPoint(x: g.visibleMaxX + 12, y: rect.midY - size.height / 2)
            } else {
                origin = NSPoint(x: g.visibleMinX, y: (r == 0 ? aboveStrip : rect.minY - 6) - size.height)
            }
        }
        let visible = visibleRect
        origin.x = max(visible.minX + 6, min(origin.x, visible.maxX - size.width - 6))
        if origin.y < visible.minY + 4 {
            // No room above: under the row, or under the table for a column.
            origin.y = (sel.isColumn ? g.bottom : rect.maxY) + 6
        }
        tableToolbar.frame = NSRect(origin: origin, size: size)
        tableToolbar.isHidden = false
    }

    /// The controller's selection changed: redraw, and hide the caret while a whole row
    /// or column is what is selected.
    func tableSelectionDidChange() {
        updateInsertionPointColor()
        updateTableChrome()
        updateSelectionOverlay()
    }

    /// Keys while a row or column is selected. Returns whether the key was used.
    private func handleTableSelectionKey(_ event: NSEvent) -> Bool {
        guard let controller, controller.tableSelection != nil else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.contains(.command) { return false }   // menu shortcuts: copy, cut, table commands
        switch event.keyCode {
        case 53:  // Esc: back to the cell
            controller.clearTableSelection(); return true
        case 51, 117:  // ⌫, ⌦
            guard mods.isEmpty else { break }
            controller.deleteTableSelection(); return true
        case 123, 124, 125, 126:  // arrows step the selection along
            guard mods.isEmpty else { break }
            let delta = event.keyCode == 123 || event.keyCode == 126 ? -1 : 1
            if controller.moveTableSelection(by: delta, vertical: event.keyCode >= 125) { return true }
        case 36, 76:  // Return: edit the first cell
            controller.clearTableSelection(); return true
        default:
            break
        }
        controller.clearTableSelection()
        return false
    }

    /// Visible table scroll bars, for tests.
    var visibleTableScrollBars: [TableScrollBar] { tableScrollBars.filter { !$0.isHidden } }

    @objc private func clipBoundsDidChange(_ note: Notification) { updateTableScrollBars() }

    // MARK: - Selection above the text

    private lazy var selectionOverlay: SelectionOverlayView = {
        let v = SelectionOverlayView(frame: bounds)
        v.textView = self
        v.autoresizingMask = [.width, .height]
        return v
    }()

    /// Keep the overlay on top of the text (TextKit adds its content views lazily) with
    /// the block cursor above it and chrome placed on the page (`overlayViews` that are
    /// subviews) above both, and keep AppKit's own selection hidden.
    private func updateSelectionOverlay() {
        hideSystemSelection()
        let top = [selectionOverlay] + tableScrollBars.filter { !$0.isHidden } + [tableChrome, blockCursor, tableToolbar] + overlayViews.filter { $0.superview === self }
        if Array(subviews.suffix(top.count)) != top {
            for v in top { addSubview(v, positioned: .above, relativeTo: nil) }
        }
        selectionOverlay.frame = bounds
        selectionOverlay.needsDisplay = true
    }

    /// TextKit 2 draws the selection in a private view beneath the text, in a grey of its
    /// own when the window is inactive. If AppKit ever renames it this finds nothing and
    /// both highlights show — doubled, but never missing.
    private func hideSystemSelection() {
        for v in subviews where v !== selectionOverlay && String(describing: type(of: v)).contains("TextSelectionView") {
            v.isHidden = true
        }
    }

    public override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        selectionOverlay.needsDisplay = true
    }

    public override func becomeFirstResponder() -> Bool {
        defer { selectionOverlay.needsDisplay = true }
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        defer { selectionOverlay.needsDisplay = true }
        return super.resignFirstResponder()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyDidChange(_:)), name: name, object: window)
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        }
        updateSelectionOverlay()
    }

    @objc private func windowKeyDidChange(_ note: Notification) { selectionOverlay.needsDisplay = true }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        controller?.effectiveAppearanceDidChange()
    }

    /// TextKit 2 relocates the viewport here and rebuilds the layout lazily at the next
    /// draw. NSTextFinder scrolls to the first match and asks for the match rectangles
    /// straight after; with no layout it gets none and draws no highlights until the
    /// next scroll makes it ask again. Rebuild the viewport layout right away.
    public override func scrollRangeToVisible(_ range: NSRange) {
        super.scrollRangeToVisible(range)
        textLayoutManager?.textViewportLayoutController.layoutViewport()
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        if let controller, !controller.placingTableSelection, controller.tableSelection != nil { controller.clearTableSelection() }
        updateSelectionOverlay()
        updateBlockCursor()
        updateTableChrome()
    }

    // MARK: - Checkbox clicks

    /// NSTextView shifts the container origin right when layout extends left of it, which
    /// a sideways-scrolled table does on purpose. Keep the origin at the inset, where the
    /// controller's geometry (`caretRect`, the gutter, the handles) assumes it is.
    public override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: textContainerInset.height)
    }

    public override func scrollWheel(with event: NSEvent) {
        if let controller, controller.mode != .raw {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            if controller.handleTableScroll(deltaX: event.scrollingDeltaX * scale, deltaY: event.scrollingDeltaY * scale,
                                            at: convert(event.locationInWindow, from: nil), phase: event.phase, momentumPhase: event.momentumPhase) { return }
        }
        super.scrollWheel(with: event)
    }

    public override func mouseDown(with event: NSEvent) {
        if let controller, let start = controller.pinnedTable(at: convert(event.locationInWindow, from: nil)) {
            controller.scrollTable(blockStart: start, to: 0)   // the pinned cells are a picture; bring the real ones back under the click
        }
        if let controller, event.clickCount == 1 {
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let p = convert(event.locationInWindow, from: nil)
            if mods.isEmpty, let offset = controller.characterIndex(at: p), controller.toggleTask(at: offset) { return }
            // Links: ⌘-click always follows; a plain click follows unless the caret is
            // already in the paragraph (PRD §7.1), in which case it edits the link.
            if mods == .command || mods.isEmpty, let url = controller.link(at: p),
               mods == .command || controller.plainClickFollowsLink(at: controller.characterIndex(at: p) ?? 0) {
                controller.open(url)
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: - Return: list continuation

    public override func insertNewline(_ sender: Any?) {
        guard let controller else { return super.insertNewline(sender) }
        if selectedRange().length == 0, controller.tableInsertRow(at: selectedRange().location) { return }
        if controller.completeTypedTableHeader(at: selectedRange().location) { return }
        if selectedRange().length == 0, controller.continueList(at: selectedRange().location, in: self) { return }
        super.insertNewline(sender)
    }

    public override func insertTab(_ sender: Any?) {
        guard let controller else { return super.insertTab(sender) }
        if controller.tableTab(at: selectedRange().location, forward: true) { return }
        if controller.indentListItem(at: selectedRange().location, by: 1, in: self) { return }
        super.insertTab(sender)
    }

    public override func insertBacktab(_ sender: Any?) {
        guard let controller else { return super.insertBacktab(sender) }
        if controller.tableTab(at: selectedRange().location, forward: false) { return }
        if controller.indentListItem(at: selectedRange().location, by: -1, in: self) { return }
        super.insertBacktab(sender)
    }

    // Tables: keep the caret out of concealed structure and off the hidden delimiter row;
    // folds: skip hidden lines.
    public override func moveRight(_ sender: Any?) { super.moveRight(sender); controller?.snapCaretOutOfSeparator(movingRight: true) }
    public override func moveLeft(_ sender: Any?) { super.moveLeft(sender); controller?.snapCaretOutOfSeparator(movingRight: false) }
    public override func moveDown(_ sender: Any?) {
        super.moveDown(sender)
        if let c = controller, c.isOnTableDelimiter(selectedRange().location) { super.moveDown(sender) }
        skipHiddenLines(direction: 1)
    }
    public override func moveUp(_ sender: Any?) {
        super.moveUp(sender)
        if let c = controller, c.isOnTableDelimiter(selectedRange().location) { super.moveUp(sender) }
        skipHiddenLines(direction: -1)
    }

    private func skipHiddenLines(direction: Int) {
        guard let c = controller else { return }
        let line = c.lines.line(containing: selectedRange().location)
        guard c.isLineHidden(line) else { return }
        if let target = c.visibleLine(from: line, direction: direction) ?? c.visibleLine(from: line, direction: -direction) {
            let cr = c.lines.contentRange(ofLine: target)
            setSelectedRange(NSRange(location: direction > 0 ? cr.location : cr.end, length: 0))
        }
    }

    // MARK: - Folding actions

    @objc public func foldSection(_ sender: Any?) { controller?.foldSection(containing: selectedRange().location) }
    @objc public func unfoldSection(_ sender: Any?) { controller?.unfoldSection(containing: selectedRange().location) }
    @objc public func unfoldAll(_ sender: Any?) { controller?.unfoldAll() }

    // MARK: - Copy: Markdown source or formatted text

    /// When true, plain ⌘C copies formatted text and the alternate command copies source.
    public var copiesRichTextByDefault = false

    /// What plain ⌘C copies here. View mode always copies formatted text: the source is
    /// not even on screen there, and the reason to select in a document you cannot edit
    /// is to put it somewhere else.
    public var copiesRichText: Bool { copiesRichTextByDefault || controller?.mode == .view }

    public override func copy(_ sender: Any?) {
        if copyTableSelection() { return }
        if copiesRichText { copyRichText() } else { super.copy(sender) }
    }

    public override func cut(_ sender: Any?) {
        if copyTableSelection() { controller?.deleteTableSelection(); return }
        super.cut(sender)
    }

    /// Tab-separated cells: what spreadsheets put on the pasteboard, and what a paste into
    /// a table reads.
    nonisolated static let tabSeparatedType = NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")

    /// A selected row or column goes on the pasteboard as a small Markdown table, with
    /// tab-separated cells beside it.
    private func copyTableSelection() -> Bool {
        guard let text = controller?.tableSelectionText() else { return false }
        let pb = NSPasteboard.general
        pb.declareTypes([.string, Self.tabSeparatedType], owner: nil)
        pb.setString(text.markdown, forType: .string)
        pb.setString(text.tsv, forType: Self.tabSeparatedType)
        return true
    }

    /// ⌘⇧C: copy in whichever format ⌘C does *not* use.
    @objc public func copyAlternate(_ sender: Any?) {
        if copiesRichText { super.copy(sender) } else { copyRichText() }
    }

    /// Context-menu commands, which say what they do rather than depending on the setting.
    @objc public func copyAsRichText(_ sender: Any?) { copyRichText() }
    @objc public func copyAsMarkdown(_ sender: Any?) { super.copy(sender) }

    private func copyRichText() {
        let sel = selectedRange()
        guard sel.length > 0 else { NSSound.beep(); return }
        let markdown = (string as NSString).substring(with: sel)
        // Diagrams go out drawn on paper. One not drawn that way yet goes as its source,
        // and is drawn now, so the next copy has it.
        let diagrams = controller?.diagrams
        let rich = RichTextExporter.attributedString(markdown: markdown, theme: controller?.theme ?? Theme(), baseURL: controller?.baseURL) { source, theme in
            guard case .rendered(let image)? = diagrams?.diagram(for: source, theme: theme, appearance: NSAppearance(named: .aqua)).state else { return nil }
            return image
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([rich])   // RTF + plain text
        // HTML too: some apps (Slack, Google Docs, Notion) take it in preference to RTF,
        // and a table survives the trip in either.
        if let html = RichTextExporter.html(rich) { pb.setData(html, forType: .html) }
        pb.setString(markdown, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
    }

    // MARK: - Pointer tracking

    private var trackingArea: NSTrackingArea?

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    /// Views floating above the text (the outline): siblings, or subviews when placed on
    /// the page. While the pointer is over one of them the text view must not touch the
    /// cursor or show table handles.
    public var overlayViews: [NSView] = []

    private func pointerIsOverOverlay(_ event: NSEvent) -> Bool {
        if !tableChrome.isHidden, tableChrome.part(at: convert(event.locationInWindow, from: nil)) != nil { return true }
        return (overlayViews + tableScrollBars + [tableToolbar]).contains { !$0.isHidden && $0.window === window && $0.convert($0.bounds, to: nil).contains(event.locationInWindow) }
    }

    public override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        tableChrome.pointerMoved(to: p)
        if pointerIsOverOverlay(event) { return }   // NSTextView would re-set the I-beam
        super.mouseMoved(with: event)
        // NSTextView only hands out the pointing hand for links in its text storage;
        // ours are decoration, so set it here.
        if controller?.link(at: p) != nil { NSCursor.pointingHand.set() }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        tableChrome.pointerMoved(to: nil)
    }

    // MARK: - Table operations (menu actions)

    /// Offset the context menu was opened at; menu-bar invocations use the caret.
    private var contextOffset: Int? = nil
    private var tableOffset: Int { contextOffset ?? selectedRange().location }

    private func table(_ op: EditorController.TableOperation) {
        controller?.performTableOperation(op, at: tableOffset)
        contextOffset = nil
    }
    @objc public func tableInsertRowAbove(_ sender: Any?) { table(.insertRowAbove) }
    @objc public func tableInsertRowBelow(_ sender: Any?) { table(.insertRowBelow) }
    @objc public func tableDeleteRow(_ sender: Any?) { table(.deleteRow) }
    @objc public func tableMoveRowUp(_ sender: Any?) { table(.moveRowUp) }
    @objc public func tableMoveRowDown(_ sender: Any?) { table(.moveRowDown) }
    @objc public func tableInsertColumnLeft(_ sender: Any?) { table(.insertColumnLeft) }
    @objc public func tableInsertColumnRight(_ sender: Any?) { table(.insertColumnRight) }
    @objc public func tableDeleteColumn(_ sender: Any?) { table(.deleteColumn) }
    @objc public func tableMoveColumnLeft(_ sender: Any?) { table(.moveColumnLeft) }
    @objc public func tableMoveColumnRight(_ sender: Any?) { table(.moveColumnRight) }
    @objc public func tableAlignLeft(_ sender: Any?) { table(.align(.left)) }
    @objc public func tableAlignCenter(_ sender: Any?) { table(.align(.center)) }
    @objc public func tableAlignRight(_ sender: Any?) { table(.align(.right)) }
    @objc public func tableAlignDefault(_ sender: Any?) { table(.align(.none)) }
    @objc public func tableDuplicateRow(_ sender: Any?) { table(.duplicateRow) }
    @objc public func tableSortAscending(_ sender: Any?) { table(.sort(ascending: true)) }
    @objc public func tableSortDescending(_ sender: Any?) { table(.sort(ascending: false)) }

    // MARK: - Insert Table

    private var tablePickerPopover: NSPopover?

    /// ⌥⌘T: a size picker at the caret; the table goes in on a pick.
    @objc public func insertTable(_ sender: Any?) {
        guard let controller, isEditable else { return }
        let picker = TableSizePicker(frame: .zero)
        picker.theme = controller.theme
        let vc = NSViewController()
        vc.view = picker
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.appearance = effectiveAppearance
        picker.onPick = { [weak self, weak popover] columns, rows in
            popover?.performClose(nil)
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            self.controller?.insertTable(columns: columns, rows: rows)
        }
        picker.onCancel = { [weak popover] in popover?.performClose(nil) }
        let caret = controller.caretRect(at: selectedRange().location) ?? NSRect(x: visibleRect.midX, y: visibleRect.midY, width: 1, height: 16)
        popover.show(relativeTo: caret.insetBy(dx: -1, dy: 0), of: self, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(picker)
        tablePickerPopover = popover
    }

    /// Whether Insert Table can run here: editing live, caret outside tables and code.
    var canInsertTable: Bool {
        guard let controller, isEditable, controller.mode == .live else { return false }
        let caret = selectedRange().location
        if controller.tableHit(at: caret) != nil { return false }
        if let leaf = controller.document.path(containing: caret).last, leaf.isVerbatim { return false }
        return true
    }

    static let tableActions: [(String, Selector, EditorController.TableOperation)] = [
        ("Insert Row Above", #selector(tableInsertRowAbove(_:)), .insertRowAbove),
        ("Insert Row Below", #selector(tableInsertRowBelow(_:)), .insertRowBelow),
        ("Delete Row", #selector(tableDeleteRow(_:)), .deleteRow),
        ("Duplicate Row", #selector(tableDuplicateRow(_:)), .duplicateRow),
        ("Move Row Up", #selector(tableMoveRowUp(_:)), .moveRowUp),
        ("Move Row Down", #selector(tableMoveRowDown(_:)), .moveRowDown),
        ("Insert Column Left", #selector(tableInsertColumnLeft(_:)), .insertColumnLeft),
        ("Insert Column Right", #selector(tableInsertColumnRight(_:)), .insertColumnRight),
        ("Delete Column", #selector(tableDeleteColumn(_:)), .deleteColumn),
        ("Move Column Left", #selector(tableMoveColumnLeft(_:)), .moveColumnLeft),
        ("Move Column Right", #selector(tableMoveColumnRight(_:)), .moveColumnRight),
    ]
    static let sortActions: [(String, Selector, EditorController.TableOperation)] = [
        ("A to Z", #selector(tableSortAscending(_:)), .sort(ascending: true)),
        ("Z to A", #selector(tableSortDescending(_:)), .sort(ascending: false)),
    ]
    static let alignActions: [(String, Selector, MarkdownKit.TableAlignment)] = [
        ("Left", #selector(tableAlignLeft(_:)), .left),
        ("Center", #selector(tableAlignCenter(_:)), .center),
        ("Right", #selector(tableAlignRight(_:)), .right),
        ("Default", #selector(tableAlignDefault(_:)), .none),
    ]

    /// The Table menu (also used as the context-menu section). Items target the responder chain.
    public static func makeTableMenu(target: AnyObject? = nil, includeInsert: Bool = true) -> NSMenu {
        let menu = NSMenu(title: "Table")
        if includeInsert {
            let insert = NSMenuItem(title: "Insert Table…", action: #selector(insertTable(_:)), keyEquivalent: "t")
            insert.keyEquivalentModifierMask = [.command, .option]
            insert.target = target
            menu.addItem(insert)
            menu.addItem(.separator())
        }
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!), right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let backspace = String(UnicodeScalar(NSBackspaceCharacter)!)
        let shortcuts: [EditorController.TableOperation: (String, NSEvent.ModifierFlags)] = [
            .insertRowAbove: (up, [.command, .option]), .insertRowBelow: (down, [.command, .option]),
            .deleteRow: (backspace, [.command, .option]),
            .moveRowUp: (up, [.command, .option, .control]), .moveRowDown: (down, [.command, .option, .control]),
            .insertColumnLeft: (left, [.command, .option]), .insertColumnRight: (right, [.command, .option]),
            .deleteColumn: (backspace, [.command, .option, .shift]),
            .moveColumnLeft: (left, [.command, .option, .control]), .moveColumnRight: (right, [.command, .option, .control]),
        ]
        for (title, sel, op) in tableActions {
            if op == .insertColumnLeft { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: shortcuts[op]?.0 ?? "")
            if let s = shortcuts[op] { item.keyEquivalentModifierMask = s.1 }
            item.target = target
            menu.addItem(item)
        }
        menu.addItem(.separator())
        func submenu(_ title: String, _ entries: [(String, Selector)]) {
            let sub = NSMenu(title: title)
            for (t, sel) in entries {
                let item = NSMenuItem(title: t, action: sel, keyEquivalent: "")
                item.target = target
                sub.addItem(item)
            }
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = sub
            menu.addItem(holder)
        }
        submenu("Align Column", alignActions.map { ($0.0, $0.1) })
        submenu("Sort Rows by Column", sortActions.map { ($0.0, $0.1) })
        return menu
    }

    // MARK: - Context menu

    public override func menu(for event: NSEvent) -> NSMenu? {
        // Copy: the superclass hands back a shared menu, and inserting into it would persist.
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
        // Table section first, when the click landed in a table.
        let p = convert(event.locationInWindow, from: nil)
        if let controller, let offset = controller.characterIndex(at: p), controller.tableHit(at: offset) != nil {
            contextOffset = offset
            let tableMenu = Self.makeTableMenu(target: self, includeInsert: false)
            let holder = NSMenuItem(title: "Table", action: nil, keyEquivalent: "")
            holder.submenu = tableMenu
            menu.insertItem(holder, at: 0)
            menu.insertItem(.separator(), at: 1)
        } else {
            contextOffset = nil
            if canInsertTable {
                let item = NSMenuItem(title: "Insert Table…", action: #selector(insertTable(_:)), keyEquivalent: "")
                item.target = self
                menu.insertItem(item, at: 0)
                menu.insertItem(.separator(), at: 1)
            }
        }
        // Right-click auto-selects the word (or newline) under the pointer; only offer
        // formatting when there is actual text to wrap.
        let sel = selectedRange()
        guard sel.length > 0,
              !(string as NSString).substring(with: sel).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return menu }
        var index = 0
        func insert(_ entries: [(String, Selector)]) {
            for (title, action) in entries {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.insertItem(item, at: index)
                index += 1
            }
            menu.insertItem(.separator(), at: index)
            index += 1
        }
        // Both formats, named: the ⌘C default depends on the mode and the setting, and a
        // menu should not make anyone work that out.
        insert([("Copy as Rich Text", #selector(copyAsRichText(_:))),
                ("Copy as Markdown", #selector(copyAsMarkdown(_:)))])
        insert([("Insert Link", #selector(insertLink(_:))),
                ("Bold", #selector(toggleBold(_:))),
                ("Italic", #selector(toggleItalic(_:))),
                ("Inline Code", #selector(toggleInlineCode(_:)))])
        return menu
    }

    // MARK: - Paste: a URL over a selection becomes a link (PRD §7.4)

    public override func paste(_ sender: Any?) {
        if controller?.pasteTableCells() == true { return }
        let sel = selectedRange()
        if sel.length > 0, let url = Self.pastedURL() {
            let text = (string as NSString).substring(with: sel)
            let replacement = "[\(text)](\(url))"
            guard shouldChangeText(in: sel, replacementString: replacement) else { return }
            textStorage?.replaceCharacters(in: sel, with: replacement)
            didChangeText()
            setSelectedRange(NSRange(location: sel.location + replacement.utf16.count, length: 0))
            return
        }
        super.paste(sender)
    }

    /// The pasteboard string if it is a single absolute http(s)/mailto URL.
    static func pastedURL(from pasteboard: NSPasteboard = .general) -> String? {
        guard let raw = pasteboard.string(forType: .string) else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: { $0.isWhitespace }),
              let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme != "mailto" && url.host == nil { return nil }
        return s
    }

    // MARK: - Marker toggles (⌘B ⌘I ⌘K ⌘⇧K)

    @objc public func toggleBold(_ sender: Any?) { toggle(marker: "**") }
    @objc public func toggleItalic(_ sender: Any?) { toggle(marker: "*") }
    @objc public func toggleInlineCode(_ sender: Any?) { toggle(marker: "`") }

    @objc public func insertLink(_ sender: Any?) {
        let sel = selectedRange()
        let text = (string as NSString).substring(with: sel)
        var url = ""
        if let pb = NSPasteboard.general.string(forType: .string), let u = URL(string: pb), u.scheme != nil { url = pb }
        let replacement = "[\(text)](\(url))"
        guard shouldChangeText(in: sel, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: sel, with: replacement)
        didChangeText()
        // Place the caret inside the parentheses when no URL was pasted, else after the link
        let caret = url.isEmpty ? sel.location + text.utf16.count + 3 : sel.location + replacement.utf16.count
        setSelectedRange(NSRange(location: caret, length: 0))
    }

    @objc public func toggleRevealAll(_ sender: Any?) {
        controller?.revealAll.toggle()
    }

    @objc public func setModeRaw(_ sender: Any?) { controller?.mode = .raw }
    @objc public func setModeLive(_ sender: Any?) { controller?.mode = .live }
    @objc public func setModeView(_ sender: Any?) { controller?.mode = .view }

    private func toggle(marker: String) {
        let sel = selectedRange()
        let ns = string as NSString
        let m = marker.utf16.count
        // Already wrapped? Remove the markers.
        if sel.location >= m, sel.end + m <= ns.length,
           ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: sel.end, length: m)) == marker {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            let inner = ns.substring(with: sel)
            guard shouldChangeText(in: outer, replacementString: inner) else { return }
            textStorage?.replaceCharacters(in: outer, with: inner)
            didChangeText()
            setSelectedRange(NSRange(location: outer.location, length: sel.length))
            return
        }
        let inner = ns.substring(with: sel)
        let replacement = marker + inner + marker
        guard shouldChangeText(in: sel, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: sel, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: sel.location + m, length: sel.length))
    }

    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case let a? where Self.tableActions.contains(where: { $0.1 == a }):
            guard let controller, let op = Self.tableActions.first(where: { $0.1 == a })?.2 else { return false }
            return isEditable && controller.canPerformTableOperation(op, at: tableOffset)
        case #selector(insertTable(_:)):
            return canInsertTable
        case let a? where Self.sortActions.contains(where: { $0.1 == a }):
            guard let controller, let op = Self.sortActions.first(where: { $0.1 == a })?.2 else { return false }
            return isEditable && controller.canPerformTableOperation(op, at: tableOffset)
        case let a? where Self.alignActions.contains(where: { $0.1 == a }):
            guard let controller, let align = Self.alignActions.first(where: { $0.1 == a }) else { return false }
            if let mi = item as? NSMenuItem { mi.state = controller.tableColumnAlignment(at: tableOffset) == align.2 ? .on : .off }
            return isEditable && controller.canPerformTableOperation(.align(align.2), at: tableOffset)
        case #selector(copyAlternate(_:)):
            if let mi = item as? NSMenuItem { mi.title = copiesRichText ? "Copy as Markdown" : "Copy as Rich Text" }
            return selectedRange().length > 0
        case #selector(copyAsRichText(_:)), #selector(copyAsMarkdown(_:)):
            return selectedRange().length > 0
        case #selector(setModeRaw(_:)), #selector(setModeLive(_:)), #selector(setModeView(_:)):
            if let mi = item as? NSMenuItem, let mode = controller?.mode {
                let target: EditorController.Mode = item.action == #selector(setModeRaw(_:)) ? .raw : item.action == #selector(setModeLive(_:)) ? .live : .view
                mi.state = mode == target ? .on : .off
            }
            return true
        case #selector(toggleRevealAll(_:)):
            if let mi = item as? NSMenuItem { mi.state = (controller?.revealAll ?? false) ? .on : .off }
            return true
        case #selector(toggleBold(_:)), #selector(toggleItalic(_:)), #selector(toggleInlineCode(_:)), #selector(insertLink(_:)):
            return isEditable
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}


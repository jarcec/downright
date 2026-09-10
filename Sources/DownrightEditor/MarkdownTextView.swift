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
        insertionPointColor = (vim.isEnabled && vim.mode != .insert) ? .clear : .textColor
        updateBlockCursor()
    }

    func modeDidChange() { if controller?.mode != .live { hideTableHandles() } }

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
        updateBlockCursor()
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        updateBlockCursor()
    }

    // MARK: - Checkbox clicks

    public override func mouseDown(with event: NSEvent) {
        if let controller, event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .option]).isEmpty {
            let p = convert(event.locationInWindow, from: nil)
            if let offset = controller.characterIndex(at: p), controller.toggleTask(at: offset) { return }
        }
        super.mouseDown(with: event)
    }

    // MARK: - Return: list continuation

    public override func insertNewline(_ sender: Any?) {
        guard let controller else { return super.insertNewline(sender) }
        if selectedRange().length == 0, controller.tableInsertRow(at: selectedRange().location) { return }
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

    public override func copy(_ sender: Any?) {
        if copiesRichTextByDefault { copyRichText() } else { super.copy(sender) }
    }

    /// ⌘⇧C: copy in whichever format ⌘C does *not* use.
    @objc public func copyAlternate(_ sender: Any?) {
        if copiesRichTextByDefault { super.copy(sender) } else { copyRichText() }
    }

    private func copyRichText() {
        let sel = selectedRange()
        guard sel.length > 0 else { NSSound.beep(); return }
        let markdown = (string as NSString).substring(with: sel)
        let rich = RichTextExporter.attributedString(markdown: markdown, theme: controller?.theme ?? Theme())
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([rich])   // RTF + plain text
        pb.setString(markdown, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
    }

    // MARK: - Table hover handles (add column / add row)

    private lazy var addColumnButton: NSButton = makeHandle(action: #selector(handleAddColumn(_:)), tip: "Add column")
    private lazy var addRowButton: NSButton = makeHandle(action: #selector(handleAddRow(_:)), tip: "Add row")
    private var handleTableOffset: Int? = nil
    private var handleZone: NSRect = .zero
    private var trackingArea: NSTrackingArea?

    private func makeHandle(action: Selector, tip: String) -> NSButton {
        let b = NSButton(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        b.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: tip)
        b.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        b.contentTintColor = .controlAccentColor
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.toolTip = tip
        b.target = self
        b.action = action
        b.isHidden = true
        b.wantsLayer = true
        b.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        b.layer?.cornerRadius = 9
        addSubview(b)
        return b
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    /// Sibling views floating above the text (the outline). While the pointer is over one
    /// of them the text view must not touch the cursor or show table handles.
    public var overlayViews: [NSView] = []

    private func pointerIsOverOverlay(_ event: NSEvent) -> Bool {
        overlayViews.contains { !$0.isHidden && $0.window === window && $0.convert($0.bounds, to: nil).contains(event.locationInWindow) }
    }

    public override func mouseMoved(with event: NSEvent) {
        if pointerIsOverOverlay(event) { hideTableHandles(); return }   // NSTextView would re-set the I-beam
        super.mouseMoved(with: event)
        updateTableHandles(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateTableHandles(at: nil)
    }

    /// Show the add-column / add-row handles for the table under `point` (text view
    /// coordinates), or hide them. Public for tests.
    public func updateTableHandles(at point: NSPoint?) {
        guard let controller, isEditable, controller.mode == .live, let point else { return hideTableHandles() }
        // Keep them while the pointer is on a handle itself or in the slack around the table.
        if handleTableOffset != nil, handleZone.contains(point) { return }
        guard let offset = controller.characterIndex(at: point), let hit = controller.tableHit(at: offset),
              let boundaries = controller.engine.tableBoundaries(at: offset), let last = boundaries.last,
              let headerRect = controller.caretRect(at: hit.table.header.range.location),
              let lastRow = hit.table.allRows.last, let lastRect = controller.caretRect(at: lastRow.range.location) else {
            return hideTableHandles()
        }
        let hasLeadingPipe = (hit.table.header.separators.first?.length ?? 0) > 0
        let left = headerRect.minX - (hasLeadingPipe ? 0 : DecorationEngine.cellGutter)
        let tableRect = NSRect(x: left, y: headerRect.minY, width: last, height: lastRect.maxY - headerRect.minY)
        handleTableOffset = hit.block.range.location
        handleZone = tableRect.insetBy(dx: -28, dy: -28)
        addColumnButton.frame.origin = NSPoint(x: tableRect.maxX + 4, y: headerRect.midY - 9)
        addRowButton.frame.origin = NSPoint(x: tableRect.midX - 9, y: tableRect.maxY + 2)
        addColumnButton.isHidden = false
        addRowButton.isHidden = false
    }

    private func hideTableHandles() {
        handleTableOffset = nil
        addColumnButton.isHidden = true
        addRowButton.isHidden = true
    }

    public var tableHandlesVisible: Bool { !addColumnButton.isHidden }

    @objc private func handleAddColumn(_ sender: Any?) {
        guard let controller, let start = handleTableOffset, let hit = controller.tableHit(at: start),
              let lastCell = hit.table.header.cells.last else { return }
        controller.performTableOperation(.insertColumnRight, at: lastCell.range.location)
        window?.makeFirstResponder(self)
        hideTableHandles()
    }

    @objc private func handleAddRow(_ sender: Any?) {
        guard let controller, let start = handleTableOffset, let hit = controller.tableHit(at: start),
              let lastRow = hit.table.allRows.last else { return }
        controller.performTableOperation(.insertRowBelow, at: lastRow.range.location + (lastRow.cells.first?.range.location ?? 0) - lastRow.range.location)
        window?.makeFirstResponder(self)
        hideTableHandles()
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

    static let tableActions: [(String, Selector, EditorController.TableOperation)] = [
        ("Insert Row Above", #selector(tableInsertRowAbove(_:)), .insertRowAbove),
        ("Insert Row Below", #selector(tableInsertRowBelow(_:)), .insertRowBelow),
        ("Delete Row", #selector(tableDeleteRow(_:)), .deleteRow),
        ("Move Row Up", #selector(tableMoveRowUp(_:)), .moveRowUp),
        ("Move Row Down", #selector(tableMoveRowDown(_:)), .moveRowDown),
        ("Insert Column Left", #selector(tableInsertColumnLeft(_:)), .insertColumnLeft),
        ("Insert Column Right", #selector(tableInsertColumnRight(_:)), .insertColumnRight),
        ("Delete Column", #selector(tableDeleteColumn(_:)), .deleteColumn),
        ("Move Column Left", #selector(tableMoveColumnLeft(_:)), .moveColumnLeft),
        ("Move Column Right", #selector(tableMoveColumnRight(_:)), .moveColumnRight),
    ]
    static let alignActions: [(String, Selector, MarkdownKit.TableAlignment)] = [
        ("Left", #selector(tableAlignLeft(_:)), .left),
        ("Center", #selector(tableAlignCenter(_:)), .center),
        ("Right", #selector(tableAlignRight(_:)), .right),
        ("Default", #selector(tableAlignDefault(_:)), .none),
    ]

    /// The Table menu (also used as the context-menu section). Items target the responder chain.
    public static func makeTableMenu(target: AnyObject? = nil) -> NSMenu {
        let menu = NSMenu(title: "Table")
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
        for (i, (title, sel, op)) in tableActions.enumerated() {
            if i == 5 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: shortcuts[op]?.0 ?? "")
            if let s = shortcuts[op] { item.keyEquivalentModifierMask = s.1 }
            item.target = target
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let align = NSMenu(title: "Align Column")
        for (title, sel, _) in alignActions {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = target
            align.addItem(item)
        }
        let alignItem = NSMenuItem(title: "Align Column", action: nil, keyEquivalent: "")
        alignItem.submenu = align
        menu.addItem(alignItem)
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
            let tableMenu = Self.makeTableMenu(target: self)
            let holder = NSMenuItem(title: "Table", action: nil, keyEquivalent: "")
            holder.submenu = tableMenu
            menu.insertItem(holder, at: 0)
            menu.insertItem(.separator(), at: 1)
        } else {
            contextOffset = nil
        }
        // Right-click auto-selects the word (or newline) under the pointer; only offer
        // formatting when there is actual text to wrap.
        let sel = selectedRange()
        guard sel.length > 0,
              !(string as NSString).substring(with: sel).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return menu }
        let items: [(String, Selector)] = [
            ("Insert Link", #selector(insertLink(_:))),
            ("Bold", #selector(toggleBold(_:))),
            ("Italic", #selector(toggleItalic(_:))),
            ("Inline Code", #selector(toggleInlineCode(_:))),
        ]
        var index = 0
        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: index)
            index += 1
        }
        menu.insertItem(.separator(), at: index)
        return menu
    }

    // MARK: - Paste: a URL over a selection becomes a link (PRD §7.4)

    public override func paste(_ sender: Any?) {
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
        case let a? where Self.alignActions.contains(where: { $0.1 == a }):
            guard let controller, let align = Self.alignActions.first(where: { $0.1 == a }) else { return false }
            if let mi = item as? NSMenuItem { mi.state = controller.tableColumnAlignment(at: tableOffset) == align.2 ? .on : .off }
            return isEditable && controller.canPerformTableOperation(.align(align.2), at: tableOffset)
        case #selector(copyAlternate(_:)):
            if let mi = item as? NSMenuItem { mi.title = copiesRichTextByDefault ? "Copy as Markdown" : "Copy as Rich Text" }
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


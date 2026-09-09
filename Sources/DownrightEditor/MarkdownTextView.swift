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

    // Tables: keep the caret out of concealed structure and off the hidden delimiter row.
    public override func moveRight(_ sender: Any?) { super.moveRight(sender); controller?.snapCaretOutOfSeparator(movingRight: true) }
    public override func moveLeft(_ sender: Any?) { super.moveLeft(sender); controller?.snapCaretOutOfSeparator(movingRight: false) }
    public override func moveDown(_ sender: Any?) {
        super.moveDown(sender)
        if let c = controller, c.isOnTableDelimiter(selectedRange().location) { super.moveDown(sender) }
    }
    public override func moveUp(_ sender: Any?) {
        super.moveUp(sender)
        if let c = controller, c.isOnTableDelimiter(selectedRange().location) { super.moveUp(sender) }
    }

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

    // MARK: - Context menu

    public override func menu(for event: NSEvent) -> NSMenu? {
        // Copy: the superclass hands back a shared menu, and inserting into it would persist.
        let menu = (super.menu(for: event)?.copy() as? NSMenu) ?? NSMenu()
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


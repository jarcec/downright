import AppKit
import MarkdownKit

/// The editing surface. Plain-text NSTextView on TextKit 2 with Markdown-aware
/// keyboard behaviour; rendering lives in the content-storage delegate.
@MainActor
public final class MarkdownTextView: NSTextView {
    weak var controller: EditorController?

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
        guard let controller, selectedRange().length == 0, controller.continueList(at: selectedRange().location, in: self) else {
            super.insertNewline(sender); return
        }
    }

    public override func insertTab(_ sender: Any?) {
        guard let controller, controller.indentListItem(at: selectedRange().location, by: 1, in: self) else {
            super.insertTab(sender); return
        }
    }

    public override func insertBacktab(_ sender: Any?) {
        guard let controller, controller.indentListItem(at: selectedRange().location, by: -1, in: self) else {
            super.insertBacktab(sender); return
        }
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
        case #selector(toggleBold(_:)), #selector(toggleItalic(_:)), #selector(toggleInlineCode(_:)),
             #selector(insertLink(_:)), #selector(toggleRevealAll(_:)):
            if let mi = item as? NSMenuItem, item.action == #selector(toggleRevealAll(_:)) {
                mi.state = (controller?.revealAll ?? false) ? .on : .off
            }
            return isEditable
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}


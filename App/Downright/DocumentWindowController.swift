import AppKit
import DownrightEditor

final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let editor: EditorController

    init(document: MarkdownDocument) {
        editor = EditorController(textStorage: document.textStorage)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 940),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = editor.scrollView
        window.minSize = NSSize(width: 360, height: 240)
        window.tabbingMode = .preferred
        window.center()
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func windowDidLoad() {
        super.windowDidLoad()
    }

    override var document: AnyObject? {
        didSet { window?.makeFirstResponder(editor.textView) }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document?.undoManager
    }

    /// Called after the document re-read its file (external change, revert).
    func documentDidReload() {
        editor.reparseAll()
    }
}

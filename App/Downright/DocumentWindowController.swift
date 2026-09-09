import AppKit
import DownrightEditor

final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let editor: EditorController
    private let gutter: LineNumberGutterView
    private let outline = OutlineOverlayView(frame: .zero)
    private let statusBar = StatusBarView(frame: .zero)

    init(document: MarkdownDocument) {
        editor = EditorController(textStorage: document.textStorage)
        gutter = LineNumberGutterView(controller: editor)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 940),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 360, height: 240)
        window.tabbingMode = .preferred
        window.center()
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true

        // Content: gutter | scroll view, with the outline floating top-right above the text.
        let container = NSView()
        let scroll = editor.scrollView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(gutter)
        container.addSubview(scroll)
        container.addSubview(outline)
        container.addSubview(statusBar)
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            gutter.topAnchor.constraint(equalTo: container.topAnchor),
            gutter.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            outline.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            outline.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
        ])
        window.contentView = container

        outline.onSelect = { [weak self] offset in self?.editor.scroll(to: offset) }
        outline.isCollapsed = Settings.outlineCollapsed
        outline.onCollapsedChange = { Settings.outlineCollapsed = $0 }
        editor.onDocumentChange = { [weak self] in self?.documentChanged() }
        editor.onSelectionChange = { [weak self] in self?.selectionChanged() }

        applySettings()
        documentChanged()
        selectionChanged()
        DebugLog.write("window init: lineNumbers=\(Settings.showLineNumbers) outline=\(Settings.showOutline) gutter=\(gutter.thickness) headings=\(editor.headings().count) outlineHidden=\(outline.isHidden)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let w = self.window else { return }
            DebugLog.write("frames: content=\(w.contentView?.frame ?? .zero) scroll=\(self.editor.scrollView.frame) tv=\(self.editor.textView.frame) gutter=\(self.gutter.frame) outline=\(self.outline.frame) status=\(self.statusBar.frame) ambiguous=\(self.editor.scrollView.hasAmbiguousLayout)")
        }
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged(_:)), name: UserDefaults.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var document: AnyObject? {
        didSet { window?.makeFirstResponder(editor.textView) }
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        document?.undoManager
    }

    func windowDidResize(_ notification: Notification) {
        outline.maxHeight = max(120, (window?.contentView?.bounds.height ?? 600) * 0.5)
    }

    /// Called after the document re-read its file (external change, revert).
    func documentDidReload() {
        editor.reparseAll()
    }

    // MARK: - Settings and chrome

    @objc private func defaultsChanged(_ note: Notification) {
        applySettings()
    }

    private func applySettings() {
        gutter.isHidden = !Settings.showLineNumbers
        outline.isHidden = !Settings.showOutline || editor.headings().isEmpty
        outline.isCollapsed = Settings.outlineCollapsed
    }

    private var stats = EditorController.Statistics(lines: 0, words: 0, characters: 0)

    private func documentChanged() {
        gutter.recomputeThickness()
        gutter.needsDisplay = true
        outline.reload(editor.headings())
        outline.isHidden = !Settings.showOutline || editor.headings().isEmpty
        stats = editor.statistics()
        statusBar.trailingText = editor.detectedDialect.summary
        updateStatusLeading()
    }

    private func selectionChanged() {
        gutter.needsDisplay = true
        outline.highlightHeading(containing: editor.textView.selectedRange().location)
        updateStatusLeading()
    }

    private func updateStatusLeading() {
        let pos = editor.caretPosition()
        let f = NumberFormatter(); f.numberStyle = .decimal
        func n(_ v: Int) -> String { f.string(from: NSNumber(value: v)) ?? "\(v)" }
        statusBar.leadingText = "Ln \(pos.line), Col \(pos.column)   ·   \(n(stats.lines)) lines   \(n(stats.words)) words   \(n(stats.characters)) chars"
    }
}

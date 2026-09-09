import AppKit
import DownrightEditor

final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    /// Set by File > New (⌘N): the next window opens standalone instead of joining the
    /// document tab group. ⌘T and Open… tab into the current window.
    static var nextWindowOpensStandalone = false

    /// Files delivered by Launch Services in one request (`downright -p a b`, a Finder
    /// multi-select) open as tabs in one *new* window: the first becomes the batch host,
    /// the rest join it. Separate requests get separate windows.
    private static var inOpenBatch = false
    private static var batchHost: NSWindow?

    static func beginOpenBatch() {
        inOpenBatch = true
        batchHost = nil
        nextWindowOpensStandalone = true
    }

    static func endOpenBatch() {
        inOpenBatch = false
        batchHost = nil
        nextWindowOpensStandalone = false
    }

    let editor: EditorController
    private let gutter: LineNumberGutterView
    private let outline = OutlineOverlayView(frame: .zero)
    private let statusBar = StatusBarView(frame: .zero)
    private let notice = NoticeBarView(frame: .zero)

    init(document: MarkdownDocument) {
        editor = EditorController(textStorage: document.textStorage, theme: Settings.theme)
        gutter = LineNumberGutterView(controller: editor)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 940),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 360, height: 240)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "DownrightDocument"
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
        container.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: container.topAnchor),
            notice.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            gutter.topAnchor.constraint(equalTo: notice.bottomAnchor),
            gutter.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: notice.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            outline.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 12),
            outline.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
        ])
        window.contentView = container

        // Join the existing document tab group. Automatic tabbing only attaches to the
        // key window, which does not exist yet when several files arrive in one open
        // request (`downright -p a.md b.md`), so do it explicitly.
        DebugLog.write("window for \(document.fileURL?.lastPathComponent ?? "untitled"): standalone=\(Self.nextWindowOpensStandalone) inBatch=\(Self.inOpenBatch) host=\(Self.batchHost != nil) visibleDocWindows=\(NSApp.windows.filter { $0.isVisible && $0.windowController is DocumentWindowController }.count)")
        if Self.nextWindowOpensStandalone {
            Self.nextWindowOpensStandalone = false
            // Disallow tabbing while the window is shown — with "Prefer tabs: Always" in
            // System Settings, .automatic would still tab it onto the key window — then
            // re-enable so ⌘T and batch mates can join this window later.
            window.tabbingMode = .disallowed
            DispatchQueue.main.async { [weak window] in window?.tabbingMode = .preferred }
            if Self.inOpenBatch { Self.batchHost = window }
        } else if Self.inOpenBatch, let host = Self.batchHost {
            host.addTabbedWindow(window, ordered: .above)
        } else if let host = NSApp.windows.last(where: { $0 !== window && $0.tabbingIdentifier == window.tabbingIdentifier && $0.windowController is DocumentWindowController }) {
            host.addTabbedWindow(window, ordered: .above)
            // A real file arriving next to an empty, untouched Untitled (the one the launch
            // created before the open-documents event landed) replaces it.
            if document.fileURL != nil, let hostDoc = host.windowController?.document as? MarkdownDocument,
               hostDoc.fileURL == nil, !hostDoc.isDocumentEdited, hostDoc.textStorage.length == 0 {
                DispatchQueue.main.async { hostDoc.close() }
            }
        }

        outline.onSelect = { [weak self] offset in self?.editor.scroll(to: offset) }
        editor.textView.overlayViews = [outline]
        outline.isCollapsed = Settings.outlineCollapsed
        outline.onCollapsedChange = { Settings.outlineCollapsed = $0 }
        document.externalChangeWhileEdited = { [weak self] in self?.showExternalChangeNotice() }
        if ProcessInfo.processInfo.environment["DOWNRIGHT_DEBUG_NOTICE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showExternalChangeNotice() }
        }
        statusBar.onModeChange = { [weak self] mode in self?.editor.mode = mode; self?.window?.makeFirstResponder(self?.editor.textView) }
        editor.onModeChange = { [weak self] mode in self?.statusBar.mode = mode }
        if let m = ProcessInfo.processInfo.environment["DOWNRIGHT_DEBUG_MODE"] {   // screenshots
            editor.mode = m == "raw" ? .raw : m == "view" ? .view : .live
        }
        editor.textView.vim.onStateChange = { [weak self] in self?.updateStatusLeading() }
        editor.textView.vim.onExCommand = { [weak self] cmd in self?.runExCommand(cmd) }
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
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged(_:)), name: Settings.didChange, object: nil)
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
        notice.hide()
    }

    /// The file changed on disk while this document has unsaved edits (TRD §8).
    private func showExternalChangeNotice() {
        guard let doc = document as? MarkdownDocument else { return }
        let name = doc.fileURL?.lastPathComponent ?? "This file"
        notice.show("\(name) was changed on disk while you have unsaved edits.", actions: [
            ("Keep Mine", { [weak doc] in doc?.keepEditsDespiteExternalChange() }),
            ("Reload from Disk", { [weak doc] in doc?.reloadFromDisk() }),
        ])
    }

    // MARK: - Settings and chrome

    @objc private func defaultsChanged(_ note: Notification) {
        applySettings()
    }

    private func applySettings() {
        gutter.isHidden = !Settings.showLineNumbers
        outline.isHidden = !Settings.showOutline || editor.headings().isEmpty
        outline.isCollapsed = Settings.outlineCollapsed
        editor.textView.vim.isEnabled = Settings.vimMode
        editor.textView.copiesRichTextByDefault = Settings.copyRichText
        editor.theme = Settings.theme
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
        var text = "Ln \(pos.line), Col \(pos.column)   ·   \(n(stats.lines)) lines   \(n(stats.words)) words   \(n(stats.characters)) chars"
        let vim = editor.textView.vim
        if vim.isEnabled { text = vim.statusText + "   ·   " + text }
        statusBar.leadingText = text
    }

    // MARK: - Vim ex commands

    private func runExCommand(_ cmd: String) {
        guard let doc = document as? NSDocument else { return }
        switch cmd {
        case "w":
            doc.save(nil)
        case "q":
            window?.performClose(nil)
        case "wq", "x":
            if doc.fileURL != nil {
                doc.save(nil)
                window?.performClose(nil)
            } else {
                doc.save(nil)   // untitled: the save panel decides; user can :q afterwards
            }
        case "q!":
            doc.updateChangeCount(.changeCleared)
            window?.close()
        default:
            NSSound.beep()
        }
    }
}

import AppKit
import DownrightEditor

final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    /// Set by File > New (⌘N): the next window opens standalone instead of joining the
    /// document tab group. ⌘T and Open… tab into the current window.
    static var nextWindowOpensStandalone = false

    /// Files delivered by Launch Services in one request (`downright a b`, a Finder
    /// multi-select) open as tabs in one *new* window: the first becomes the batch host,
    /// the rest join it. Separate requests get separate windows.
    private static var inOpenBatch = false
    private static var batchHost: NSWindow?
    /// A document opened by following a link becomes a tab of the window it was
    /// clicked in, whichever window happens to be last in the list.
    private static var linkHost: NSWindow?

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
    /// On the page the outline scrolls away with the top of the document; this collapsed
    /// pill then stands in for it in the window's corner.
    private let outlinePill = OutlineOverlayView(frame: .zero)
    /// The document's own choice of outline mode (View › Outline Position), if it made
    /// one; otherwise `Settings.outlineMode` applies.
    private var chosenOutlineMode: OutlineMode?
    private var outlineMode: OutlineMode { chosenOutlineMode ?? Settings.outlineMode }
    private let content = NSView()
    private lazy var outlineCorner = [outlineTop, outline.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28)]
    private var outlineOnPage: (leading: NSLayoutConstraint, top: NSLayoutConstraint)?
    private lazy var pillTop = outlinePill.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 12)
    private var placingOutline = false
    private let statusBar = StatusBarView(frame: .zero)
    private let notice = NoticeBarView(frame: .zero)
    private lazy var outlineTop = outline.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 12)
    /// Live while this window hosts the tab bar; see `observeTabGroup()`.
    private var tabGroupObservers: [NSKeyValueObservation] = []
    /// Save As moves the document: relative image paths follow it.
    private var fileURLObserver: NSKeyValueObservation?

    /// Keep the outline below the find bar. Modern NSScrollView floats the bar over the
    /// top of the scroll view and offsets the text with content insets, so the clip view's
    /// frame does not change; use the bar's own height.
    private func findBarDidRetile() {
        let scroll = editor.scrollView
        let barHeight = scroll.isFindBarVisible ? (scroll.findBarView?.frame.height ?? 0) : 0
        let constant = 12 + barHeight
        if abs(outlineTop.constant - constant) > 0.5 { outlineTop.constant = constant }
        if abs(pillTop.constant - constant) > 0.5 { pillTop.constant = constant }
    }

    init(document: MarkdownDocument) {
        editor = EditorController(textStorage: document.textStorage, theme: Settings.theme)
        gutter = LineNumberGutterView(controller: editor)

        // Reuse the frame the user last left a document window at (per machine, so it
        // lives in defaults rather than the shared settings file); cascade from there.
        let saved = Self.savedFrame()
        let window = NSWindow(contentRect: saved ?? NSRect(x: 0, y: 0, width: 860, height: 940),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 360, height: 240)
        // The title bar takes the page's colour instead of its own white strip; the
        // document name, traffic lights and tab bar stay where they are.
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "DownrightDocument"
        if saved == nil { window.center() }
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true

        // Content: gutter | scroll view, with the outline floating top-right over the text
        // or, in page mode, on the page inside the text view (see `placeOutline()`).
        let container = content
        let scroll = editor.scrollView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(gutter)
        container.addSubview(scroll)
        container.addSubview(outline)
        container.addSubview(outlinePill)
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
            pillTop,
            outlinePill.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
        ] + outlineCorner)
        window.contentView = container
        // The find bar (⌘F) takes the top of the scroll view and pushes the text area
        // down; keep the outline below it by following the clip view's top edge.
        (scroll as? EditorScrollView)?.onTile = { [weak self] in self?.findBarDidRetile() }

        // Join the existing document tab group. Automatic tabbing only attaches to the
        // key window, which does not exist yet when several files arrive in one open
        // request (`downright a.md b.md`), so do it explicitly.
        DebugLog.write("window for \(document.fileURL?.lastPathComponent ?? "untitled"): standalone=\(Self.nextWindowOpensStandalone) inBatch=\(Self.inOpenBatch) host=\(Self.batchHost != nil) visibleDocWindows=\(NSApp.windows.filter { $0.isVisible && $0.windowController is DocumentWindowController }.count)")
        if let host = Self.linkHost, host.isVisible, host.tabbingIdentifier == window.tabbingIdentifier {
            Self.linkHost = nil
            host.addTabbedWindow(window, ordered: .above)
        } else if Self.nextWindowOpensStandalone {
            Self.nextWindowOpensStandalone = false
            // Disallow tabbing while the window is shown — with "Prefer tabs: Always" in
            // System Settings, .automatic would still tab it onto the key window — then
            // re-enable so ⌘T and batch mates can join this window later.
            window.tabbingMode = .disallowed
            DispatchQueue.main.async { [weak window] in window?.tabbingMode = .preferred }
            if Self.inOpenBatch { Self.batchHost = window }
        } else if Self.inOpenBatch, let host = Self.batchHost {
            // Each mate goes after the previous one, keeping the request's order.
            host.addTabbedWindow(window, ordered: .above)
            Self.batchHost = window
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
        outlinePill.onSelect = outline.onSelect
        editor.textView.overlayViews = [outline, outlinePill]
        outline.isCollapsed = Settings.outlineCollapsed
        outline.onCollapsedChange = { Settings.outlineCollapsed = $0 }
        outline.onSizeChange = { [weak self] in self?.placeOutline() }
        outline.onToggleMode = { [weak self] in
            guard let self else { return }
            self.setOutlineMode(self.outlineMode == .page ? .overlay : .page)
        }
        outlinePill.isCollapsed = true
        outlinePill.isHidden = true
        editor.onPageFloatChange = { [weak self] in self?.placeOutline() }
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(editorDidScroll(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        chosenOutlineMode = OutlineMode.remembered(for: document.fileURL)
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
        editor.onFoldsChange = { [weak self] in self?.gutter.needsDisplay = true }
        editor.baseURL = document.fileURL
        editor.onOpenLink = { [weak self] url in self?.openLinkedDocument(url) ?? false }
        fileURLObserver = document.observe(\.fileURL) { [weak self] doc, _ in
            Task { @MainActor in
                self?.editor.baseURL = doc.fileURL
                // A choice made while untitled, or under the old name, follows the file.
                if let self, let url = doc.fileURL, let mode = self.chosenOutlineMode { OutlineMode.remember(mode, for: url) }
            }
        }

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

    // MARK: - Remembering the window frame

    private static let frameKey = "DocumentWindowFrame"

    private static func savedFrame() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: frameKey) else { return nil }
        let r = NSRectFromString(s)
        guard r.width >= 360, r.height >= 240 else { return nil }
        // Only if it still lands on a screen.
        return NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) ? r : nil
    }

    private func rememberFrame() {
        guard let w = window, !w.isMiniaturized, !w.styleMask.contains(.fullScreen) else { return }
        UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: Self.frameKey)
    }

    func windowDidEndLiveResize(_ notification: Notification) { rememberFrame() }
    func windowDidMove(_ notification: Notification) { rememberFrame() }

    func windowDidResize(_ notification: Notification) {
        outline.maxHeight = max(120, (window?.contentView?.bounds.height ?? 600) * 0.5)
        outlinePill.maxHeight = outline.maxHeight
        if window?.inLiveResize == false {
            rememberFrame()   // zoom / programmatic resizes
            // Showing or hiding the tab bar resizes the content, and a bar that has just
            // appeared comes in the system's colours.
            applyTabBarTheme()
        }
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

    // MARK: - Links

    /// A link to a file Downright can open (Markdown, plain text) opens as a tab next
    /// to this one, or brings its tab forward if it is already open; a `#fragment`
    /// then jumps to that heading. Anything else is left to the system.
    private func openLinkedDocument(_ url: URL) -> Bool {
        guard url.isFileURL, var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return false }
        let fragment = parts.fragment
        parts.fragment = nil
        guard let file = parts.url?.standardizedFileURL else { return false }
        let controller = NSDocumentController.shared
        guard (try? controller.typeForContents(of: file)) != nil else { return false }
        DebugLog.write("link opens \(file.lastPathComponent)\(fragment.map { "#\($0)" } ?? "") as a tab")
        Self.linkHost = window
        controller.openDocument(withContentsOf: file, display: true) { doc, _, error in
            Self.linkHost = nil
            if let error { docLog.error("link open failed for \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            guard let fragment, !fragment.isEmpty,
                  let target = doc?.windowControllers.compactMap({ $0 as? DocumentWindowController }).first else { return }
            // A window that has just been made has not laid out yet; let it, then jump.
            DispatchQueue.main.async { target.editor.scroll(toHeading: fragment) }
        }
        return true
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
        editor.images.loadsRemoteImages = Settings.loadRemoteImages
        editor.theme = Settings.theme
        editor.maxContentWidth = CGFloat(Settings.maxContentWidth)
        applyTheme()
        placeOutline()
    }

    /// The theme reaches past the text: the gutter, the floating outline, the tab bar and
    /// the window itself, so a warm page does not sit in grey chrome.
    private func applyTheme() {
        let theme = editor.theme
        outline.theme = theme
        outlinePill.theme = theme
        gutter.needsDisplay = true
        window?.backgroundColor = theme.backgroundColor
        statusBar.theme = theme
        applyTabBarTheme()
    }

    /// AppKit rebuilds the tab bar when the group changes and hands it to whichever tab is
    /// selected, each time in the system's own colours — so the bar is re-dressed after the
    /// run loop has laid it out, not only when the theme changes.
    private func applyTabBarTheme() {
        TabBarChrome.apply(editor.theme, to: window)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            TabBarChrome.apply(self.editor.theme, to: self.window)
        }
    }

    /// Follow the tab group: a tab added, removed or selected rebuilds the bar. The group
    /// itself only exists once this window has company, so the observers are re-made every
    /// time the window comes forward, which is also when it is handed the bar.
    private func observeTabGroup() {
        tabGroupObservers = (window?.tabGroup).map { group in
            [group.observe(\.windows) { [weak self] _, _ in Task { @MainActor in self?.applyTabBarTheme() } },
             group.observe(\.selectedWindow) { [weak self] _, _ in Task { @MainActor in self?.applyTabBarTheme() } }]
        } ?? []
    }

    func windowDidBecomeKey(_ notification: Notification) { cameForward() }
    func windowDidBecomeMain(_ notification: Notification) { cameForward() }

    private func cameForward() {
        observeTabGroup()
        applyTabBarTheme()
    }

    private var stats = EditorController.Statistics(lines: 0, words: 0, characters: 0)

    private func documentChanged() {
        gutter.recomputeThickness()
        gutter.needsDisplay = true
        outline.reload(editor.headings())
        outlinePill.reload(editor.headings())
        outline.isHidden = !Settings.showOutline || editor.headings().isEmpty
        placeOutline()
        stats = editor.statistics()
        statusBar.trailingText = editor.detectedDialect.summary
        updateStatusLeading()
    }

    // MARK: - Outline placement

    /// Over the text the outline is pinned to the window's corner. On the page it is a
    /// subview of the text view, in the slot the editor keeps clear at the top of the
    /// column, so the text wraps around it and it scrolls with the page; when the column
    /// is too narrow to keep that slot, it falls back to the corner.
    private func placeOutline() {
        guard !placingOutline else { return }
        placingOutline = true
        defer { placingOutline = false }
        outline.onPage = outlineMode == .page
        let wantsPage = outlineMode == .page && !outline.isHidden
        editor.pageFloatSize = wantsPage ? outline.panelSize : .zero
        let textView = editor.textView
        if wantsPage, let slot = editor.pageFloatRect {
            if outline.superview !== textView {
                outline.removeFromSuperview()
                textView.addSubview(outline)
                let pinned = (outline.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
                              outline.topAnchor.constraint(equalTo: textView.topAnchor))
                NSLayoutConstraint.activate([pinned.0, pinned.1])
                outlineOnPage = pinned
            }
            outlineOnPage?.leading.constant = slot.minX
            outlineOnPage?.top.constant = slot.minY
            outline.floatsOverText = false
        } else {
            if outline.superview !== content {
                outline.removeFromSuperview()
                outlineOnPage = nil
                content.addSubview(outline, positioned: .below, relativeTo: outlinePill)
                NSLayoutConstraint.activate(outlineCorner)
            }
            outline.floatsOverText = true
        }
        updateOutlinePill()
    }

    @objc private func editorDidScroll(_ note: Notification) { updateOutlinePill() }

    /// Show the pill once the outline on the page has scrolled out of sight (less than its
    /// header left showing); hide it, collapsed again, when the outline comes back.
    private func updateOutlinePill() {
        var show = false
        if outline.superview === editor.textView, !outline.isHidden, let slot = editor.pageFloatRect {
            show = slot.maxY - editor.scrollView.documentVisibleRect.minY < 24
        }
        if !show, !outlinePill.isHidden { outlinePill.isCollapsed = true }
        if outlinePill.isHidden == show { outlinePill.isHidden = !show }
    }

    /// View › Outline Position: this document only, remembered for its file.
    @objc func chooseOutlineMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = OutlineMode(rawValue: raw) else { return }
        setOutlineMode(mode)
    }

    /// The menu and the outline's own button: this document only, remembered for its file.
    private func setOutlineMode(_ mode: OutlineMode) {
        chosenOutlineMode = mode
        if let url = (document as? NSDocument)?.fileURL { OutlineMode.remember(mode, for: url) }
        placeOutline()
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(chooseOutlineMode(_:)) {
            item.state = (item.representedObject as? String) == outlineMode.rawValue ? .on : .off
        }
        return true
    }

    private func selectionChanged() {
        gutter.needsDisplay = true
        outline.highlightHeading(containing: editor.textView.selectedRange().location)
        outlinePill.highlightHeading(containing: editor.textView.selectedRange().location)
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

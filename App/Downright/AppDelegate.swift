import AppKit
import DownrightEditor

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationWillFinishLaunching(_ notification: Notification) {
        Settings.shared.load()
        Settings.applyAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged(_:)), name: Settings.didChange, object: nil)
        NSApp.mainMenu = MainMenu.build()
        DebugLog.write("willFinishLaunching: lineNumbers=\(Settings.showLineNumbers) outline=\(Settings.showOutline)")
    }

    @objc private func defaultsChanged(_ note: Notification) {
        Settings.applyAppearance()
    }

    // MARK: - Settings actions (reachable from any window via the responder chain end)

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    @objc func toggleLineNumbers(_ sender: Any?) {
        Settings.showLineNumbers.toggle()
    }

    @objc func toggleOutline(_ sender: Any?) {
        Settings.showOutline.toggle()
    }

    @objc func toggleVimMode(_ sender: Any?) {
        Settings.vimMode.toggle()
    }

    /// New untitled document as a tab of the key window (falls back to a new window).
    @objc func newTab(_ sender: Any?) {
        let host = NSApp.keyWindow ?? NSApp.mainWindow
        guard let doc = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(false) else { return }
        doc.makeWindowControllers()
        guard let window = doc.windowControllers.first?.window else { doc.showWindows(); return }
        if let host, host.tabbingIdentifier == window.tabbingIdentifier {
            host.addTabbedWindow(window, ordered: .above)
        }
        doc.showWindows()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleLineNumbers(_:)): item.state = Settings.showLineNumbers ? .on : .off
        case #selector(toggleOutline(_:)): item.state = Settings.showOutline ? .on : .off
        case #selector(toggleVimMode(_:)): item.state = Settings.vimMode ? .on : .off
        default: break
        }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        docLog.notice("launched \(Bundle.main.bundlePath, privacy: .public) sandboxed=\(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        // Application
        let appName = ProcessInfo.processInfo.processName
        let app = NSMenu(title: appName)
        app.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app))

        // File
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "New Tab", action: #selector(AppDelegate.newTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: "Open Recent")
        recent.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        file.addItem(recentItem)
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save…", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = file.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Revert to Saved…", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Page Setup…", action: #selector(NSDocument.runPageLayout(_:)), keyEquivalent: "P")
        file.addItem(withTitle: "Print…", action: #selector(NSDocument.printDocument(_:)), keyEquivalent: "p")
        main.addItem(submenu(file))

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        for (title, key, tag) in [("Find…", "f", NSTextFinder.Action.showFindInterface),
                                  ("Find and Replace…", "F", .showReplaceInterface),
                                  ("Find Next", "g", .nextMatch),
                                  ("Find Previous", "G", .previousMatch),
                                  ("Use Selection for Find", "e", .setSearchString)] {
            let item = find.addItem(withTitle: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key.lowercased())
            item.tag = tag.rawValue
            if key != key.lowercased() { item.keyEquivalentModifierMask = [.command, .shift] }
        }
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findItem.submenu = find
        edit.addItem(findItem)
        edit.addItem(.separator())
        let spelling = NSMenu(title: "Spelling and Grammar")
        spelling.addItem(withTitle: "Show Spelling and Grammar", action: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":")
        spelling.addItem(withTitle: "Check Document Now", action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
        spelling.addItem(.separator())
        spelling.addItem(withTitle: "Check Spelling While Typing", action: #selector(NSTextView.toggleContinuousSpellChecking(_:)), keyEquivalent: "")
        let spellingItem = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        spellingItem.submenu = spelling
        edit.addItem(spellingItem)
        edit.addItem(withTitle: "Emoji & Symbols", action: #selector(NSApplication.orderFrontCharacterPalette(_:)), keyEquivalent: " ").keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu(edit))

        // Format
        let format = NSMenu(title: "Format")
        format.addItem(withTitle: "Bold", action: #selector(MarkdownTextView.toggleBold(_:)), keyEquivalent: "b")
        format.addItem(withTitle: "Italic", action: #selector(MarkdownTextView.toggleItalic(_:)), keyEquivalent: "i")
        let code = format.addItem(withTitle: "Inline Code", action: #selector(MarkdownTextView.toggleInlineCode(_:)), keyEquivalent: "k")
        code.keyEquivalentModifierMask = [.command, .shift]
        format.addItem(withTitle: "Link", action: #selector(MarkdownTextView.insertLink(_:)), keyEquivalent: "k")
        main.addItem(submenu(format))

        // View
        let view = NSMenu(title: "View")
        let reveal = view.addItem(withTitle: "Reveal All Syntax", action: #selector(MarkdownTextView.toggleRevealAll(_:)), keyEquivalent: "r")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(.separator())
        view.addItem(withTitle: "Show Line Numbers", action: #selector(AppDelegate.toggleLineNumbers(_:)), keyEquivalent: "l").keyEquivalentModifierMask = [.command, .shift]
        view.addItem(withTitle: "Show Outline", action: #selector(AppDelegate.toggleOutline(_:)), keyEquivalent: "o").keyEquivalentModifierMask = [.command, .shift]
        view.addItem(withTitle: "Vim Mode", action: #selector(AppDelegate.toggleVimMode(_:)), keyEquivalent: "")
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu(view))

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Show Tab Bar", action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        window.addItem(withTitle: "Show All Tabs", action: #selector(NSWindow.toggleTabOverview(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Show Previous Tab", action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "{").keyEquivalentModifierMask = [.command, .shift]
        window.addItem(withTitle: "Show Next Tab", action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "}").keyEquivalentModifierMask = [.command, .shift]
        window.addItem(withTitle: "Merge All Windows", action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu(window))
        NSApp.windowsMenu = window

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Downright Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        main.addItem(submenu(help))
        NSApp.helpMenu = help

        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

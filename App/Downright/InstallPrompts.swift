import AppKit

/// First-launch conveniences for a directly distributed app: offer to move the bundle into
/// /Applications when it runs from Downloads or a disk image, and offer to install the
/// `downright` command once it lives in an Applications folder.
@MainActor
enum InstallPrompts {
    private static let declinedMoveKey = "declinedMoveToApplications"
    private static let declinedCLIKey = "declinedCommandLineInstall"

    static func runOnLaunch() {
        if offerMoveToApplications() { return }   // relaunching; do nothing else
        offerCommandLineTool(force: false)
    }

    // MARK: - Move to Applications

    private static var isInApplications: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Returns true when the app is relaunching from its new home.
    @discardableResult
    static func offerMoveToApplications() -> Bool {
        guard !isInApplications, !UserDefaults.standard.bool(forKey: declinedMoveKey) else { return false }
        let source = URL(fileURLWithPath: Bundle.main.bundlePath)
        let destination = URL(fileURLWithPath: "/Applications/Downright.app")
        let alert = NSAlert()
        alert.messageText = "Move Downright to the Applications folder?"
        alert.informativeText = "Downright is running from \(source.deletingLastPathComponent().path). Moving it keeps it in one place, out of Downloads, and lets the downright command find it."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Don't Move")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: declinedMoveKey)
            return false
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.trashItem(at: destination, resultingItemURL: nil) }
            let onReadOnlyVolume = (try? source.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
            if onReadOnlyVolume { try fm.copyItem(at: source, to: destination) } else { try fm.moveItem(at: source, to: destination) }
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return true
        } catch {
            let fail = NSAlert(error: error)
            fail.messageText = "Downright couldn't be moved"
            fail.runModal()
            return false
        }
    }

    // MARK: - Command-line tool

    static var shimInBundle: URL? { Bundle.main.url(forResource: "downright", withExtension: nil) }

    /// A `downright` on the PATH-ish directories we know, if any.
    static var installedCommand: URL? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/bin"] {
            let p = dir + "/downright"
            if FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }

    /// Ask (once, unless forced) to install the command. Installs into the first writable
    /// candidate directory; falls back to an administrator-authorised /usr/local/bin link.
    static func offerCommandLineTool(force: Bool) {
        guard isInApplications || force, shimInBundle != nil else { return }
        if installedCommand != nil && !force { return }
        if !force && UserDefaults.standard.bool(forKey: declinedCLIKey) { return }
        let alert = NSAlert()
        alert.messageText = "Install the downright command?"
        alert.informativeText = "Adds a `downright` command so you can open files from the terminal:\n\n    downright notes.md\n    downright -p *.md\n\nIt is a small script that hands files to this app."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: force ? "Cancel" : "Later")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else {
            if !force { UserDefaults.standard.set(true, forKey: declinedCLIKey) }
            return
        }
        installCommandLineTool()
    }

    static func installCommandLineTool() {
        guard let shim = shimInBundle else { return }
        let fm = FileManager.default
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        for dir in candidates where fm.isWritableFile(atPath: dir) || (dir.hasPrefix(NSHomeDirectory()) && !fm.fileExists(atPath: dir)) {
            do {
                if !fm.fileExists(atPath: dir) { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) }
                let link = dir + "/downright"
                if fm.fileExists(atPath: link) { try fm.removeItem(atPath: link) }
                try fm.createSymbolicLink(atPath: link, withDestinationPath: shim.path)
                report(installedAt: link, onPath: pathContains(dir))
                return
            } catch { continue }
        }
        // Nothing writable: ask for administrator rights for /usr/local/bin.
        let script = "do shell script \"mkdir -p /usr/local/bin && ln -sf '\(shim.path)' /usr/local/bin/downright\" with administrator privileges"
        var error: NSDictionary?
        if let apple = NSAppleScript(source: script), apple.executeAndReturnError(&error) != nil {
            report(installedAt: "/usr/local/bin/downright", onPath: pathContains("/usr/local/bin"))
        } else if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {   // -128: user cancelled
            let fail = NSAlert()
            fail.messageText = "The downright command couldn't be installed"
            fail.informativeText = "Create the link yourself:\n\nln -s \"\(shim.path)\" /usr/local/bin/downright"
            fail.runModal()
        }
    }

    private static func pathContains(_ dir: String) -> Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains(Substring(dir))
    }

    private static func report(installedAt link: String, onPath: Bool) {
        let done = NSAlert()
        done.messageText = "Installed"
        done.informativeText = "The command is at \(link)." + (onPath ? "" : "\n\nThat directory is not on this app's PATH; make sure it is on your shell's, or open a new terminal.")
        done.runModal()
    }
}

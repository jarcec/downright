import AppKit
import Combine
import DownrightConfig
import DownrightEditor
import Foundation

/// User settings, stored as a flat TOML file at `~/.config/downright.toml`
/// (`$XDG_CONFIG_HOME/downright.toml` when set) so they can be versioned and shared
/// with tools like chezmoi. The file is the source of truth: UI changes are written
/// back in place (comments and unknown keys survive), and external edits are picked
/// up live.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    static let didChange = Notification.Name("DownrightSettingsDidChange")

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
        /// `nil` means follow the system.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    // MARK: - Values

    @Published var showLineNumbers = true { didSet { changed() } }
    @Published var showOutline = true { didSet { changed() } }
    @Published var outlineCollapsed = false { didSet { changed() } }
    @Published var appearance: Appearance = .system { didSet { changed() } }
    @Published var vimMode = false { didSet { changed() } }
    /// ⌘C copies formatted text (⌘⇧C then copies Markdown source) instead of the reverse.
    @Published var copyRichText = false { didSet { changed() } }
    /// Colour of revealed syntax markers; nil = theme default (green).
    @Published var markerColor: NSColor? = nil { didSet { changed() } }
    /// Vim block-cursor colour; nil = theme default (lighter marker green).
    @Published var cursorColor: NSColor? = nil { didSet { changed() } }

    // Static accessors keep call sites short.
    static var showLineNumbers: Bool { get { shared.showLineNumbers } set { shared.showLineNumbers = newValue } }
    static var showOutline: Bool { get { shared.showOutline } set { shared.showOutline = newValue } }
    static var outlineCollapsed: Bool { get { shared.outlineCollapsed } set { shared.outlineCollapsed = newValue } }
    static var appearance: Appearance { get { shared.appearance } set { shared.appearance = newValue } }
    static var vimMode: Bool { get { shared.vimMode } set { shared.vimMode = newValue } }
    static var copyRichText: Bool { get { shared.copyRichText } set { shared.copyRichText = newValue } }
    static var markerColor: NSColor? { get { shared.markerColor } set { shared.markerColor = newValue } }
    static var cursorColor: NSColor? { get { shared.cursorColor } set { shared.cursorColor = newValue } }

    /// The editor theme reflecting the current settings.
    static var theme: Theme {
        var t = Theme()
        if let m = shared.markerColor { t.markerColor = m }
        if let c = shared.cursorColor { t.vimCursorColor = c }
        return t
    }

    /// Push the chosen appearance to the app. Safe to call repeatedly.
    static func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    // MARK: - File

    let fileURL: URL
    private var suppressChanges = false
    private var lastWrittenText: String?
    private var saveScheduled = false
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDescriptor: Int32 = -1

    private static let header = """
    # Downright settings — https://github.com/jarcec/downright
    # The app rewrites values in place when you change them in Settings; comments and
    # extra keys are kept, so this file is safe to manage with chezmoi.
    #
    # appearance: "system" | "light" | "dark"
    # copy_rich_text: when true, ⌘C copies formatted text and ⌘⇧C copies Markdown source
    # marker_color / cursor_color: "#RRGGBB" or "#RRGGBBAA", or "default"

    """

    private init() {
        fileURL = Self.resolveFileURL()
    }

    /// The real home directory, even inside the sandbox (NSHomeDirectory() is the container).
    private static func realHome() -> String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    private static func resolveFileURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        let base: String
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty { base = xdg } else { base = realHome() + "/.config" }
        return URL(fileURLWithPath: base).appendingPathComponent("downright.toml")
    }

    /// User-facing path with `~`.
    var displayPath: String {
        let home = Self.realHome()
        let p = fileURL.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    /// Load from disk, migrating from UserDefaults when the file does not exist yet.
    func load() {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            apply(TOML.parse(text))
            lastWrittenText = text
            DebugLog.write("settings loaded from \(fileURL.path)")
        } else {
            migrateFromUserDefaults()
            save()
            DebugLog.write("settings file created at \(fileURL.path)")
        }
        startWatching()
    }

    private func apply(_ values: [String: TOMLValue]) {
        suppressChanges = true
        defer { suppressChanges = false }
        if case .bool(let b)? = values["line_numbers"] { showLineNumbers = b }
        if case .bool(let b)? = values["outline"] { showOutline = b }
        if case .bool(let b)? = values["outline_collapsed"] { outlineCollapsed = b }
        if case .string(let s)? = values["appearance"], let a = Appearance(rawValue: s) { appearance = a }
        if case .bool(let b)? = values["vim_mode"] { vimMode = b }
        if case .bool(let b)? = values["copy_rich_text"] { copyRichText = b }
        markerColor = { if case .string(let s)? = values["marker_color"] { return Theme.color(hex: s) }; return nil }()
        cursorColor = { if case .string(let s)? = values["cursor_color"] { return Theme.color(hex: s) }; return nil }()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private var values: [String: TOMLValue] {
        var v: [String: TOMLValue] = [
            "line_numbers": .bool(showLineNumbers),
            "outline": .bool(showOutline),
            "outline_collapsed": .bool(outlineCollapsed),
            "appearance": .string(appearance.rawValue),
            "vim_mode": .bool(vimMode),
            "copy_rich_text": .bool(copyRichText),
        ]
        // Colours are written only when customised, so the defaults can evolve.
        v["marker_color"] = .string(markerColor?.hexString ?? "default")
        v["cursor_color"] = .string(cursorColor?.hexString ?? "default")
        return v
    }

    private func migrateFromUserDefaults() {
        let d = UserDefaults.standard
        suppressChanges = true
        defer { suppressChanges = false }
        if d.object(forKey: "showLineNumbers") != nil { showLineNumbers = d.bool(forKey: "showLineNumbers") }
        if d.object(forKey: "showOutline") != nil { showOutline = d.bool(forKey: "showOutline") }
        if d.object(forKey: "outlineCollapsed") != nil { outlineCollapsed = d.bool(forKey: "outlineCollapsed") }
        if let s = d.string(forKey: "appearance"), let a = Appearance(rawValue: s) { appearance = a }
        if d.object(forKey: "vimMode") != nil { vimMode = d.bool(forKey: "vimMode") }
    }

    private func changed() {
        guard !suppressChanges else { return }
        NotificationCenter.default.post(name: Self.didChange, object: self)
        scheduleSave()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    /// Write the current values into the file, editing existing lines in place.
    func save() {
        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? Self.header
        let text = TOML.updating(existing, with: values)
        guard text != lastWrittenText else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.data(using: .utf8)!.write(to: fileURL, options: .atomic)
            lastWrittenText = text
        } catch {
            DebugLog.write("settings save FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - External changes

    /// Watch the parent directory: editors and chezmoi replace the file atomically, which
    /// a watch on the file's own descriptor would lose.
    private func startWatching() {
        watcher?.cancel()
        let dir = fileURL.deletingLastPathComponent().path
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { DebugLog.write("settings watch: cannot open \(dir)"); return }
        watchedDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.reloadIfChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    private func reloadIfChanged() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8), text != lastWrittenText else { return }
        lastWrittenText = text
        apply(TOML.parse(text))
        DebugLog.write("settings reloaded after external change")
    }
}

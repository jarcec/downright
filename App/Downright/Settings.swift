import AppKit
import Combine
import UniformTypeIdentifiers
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

    // MARK: - Values

    @Published var showLineNumbers = true { didSet { changed() } }
    @Published var showOutline = true { didSet { changed() } }
    @Published var outlineCollapsed = false { didSet { changed() } }
    /// Which theme slot the app draws with: a fixed one, or macOS's choice.
    @Published var appearance: Appearance = .system { didSet { changed() } }
    /// What fills each slot.
    @Published var lightTheme: ThemeChoice = .paper { didSet { changed() } }
    @Published var darkTheme: ThemeChoice = .ink { didSet { changed() } }
    /// The Custom theme's colours per slot, `ColorToken.rawValue` → `#RRGGBBAA`. Kept on
    /// file whatever the slots are set to, so switching away and back is lossless.
    @Published var customLight: [String: String] = [:] { didSet { changed() } }
    @Published var customDark: [String: String] = [:] { didSet { changed() } }
    @Published var vimMode = false { didSet { changed() } }
    /// ⌘C copies formatted text (⌘⇧C then copies Markdown source) instead of the reverse.
    @Published var copyRichText = false { didSet { changed() } }
    /// Body text size in points.
    @Published var fontSize: Double = 15 { didSet { changed() } }
    /// Maximum text column width in points; 0 = use the full window.
    @Published var maxContentWidth: Double = 0 { didSet { changed() } }

    // Static accessors keep call sites short.
    static var showLineNumbers: Bool { get { shared.showLineNumbers } set { shared.showLineNumbers = newValue } }
    static var showOutline: Bool { get { shared.showOutline } set { shared.showOutline = newValue } }
    static var outlineCollapsed: Bool { get { shared.outlineCollapsed } set { shared.outlineCollapsed = newValue } }
    static var appearance: Appearance { get { shared.appearance } set { shared.appearance = newValue } }
    static var vimMode: Bool { get { shared.vimMode } set { shared.vimMode = newValue } }
    static var copyRichText: Bool { get { shared.copyRichText } set { shared.copyRichText = newValue } }
    static var fontSize: Double { get { shared.fontSize } set { shared.fontSize = min(max(newValue, 9), 40) } }
    static var maxContentWidth: Double { get { shared.maxContentWidth } set { shared.maxContentWidth = newValue } }

    /// The colour selection as a whole.
    static var selection: ThemeSelection {
        ThemeSelection(appearance: shared.appearance, light: shared.lightTheme, dark: shared.darkTheme,
                       customLight: shared.customLight, customDark: shared.customDark)
    }

    /// The editor theme reflecting the current settings.
    static var theme: Theme {
        var t = Theme(selection)
        t.bodySize = CGFloat(shared.fontSize)
        return t
    }

    /// The user's own colours for a slot, complete: what the colour wells show.
    static func customPalette(for slot: ThemeSlot) -> Palette {
        Palette.custom(shared.custom(for: slot), base: slot.ground)
    }

    func custom(for slot: ThemeSlot) -> [String: String] { slot == .light ? customLight : customDark }

    static func setCustom(_ hex: String, token: ColorToken, slot: ThemeSlot) {
        if slot == .light { shared.customLight[token.rawValue] = hex } else { shared.customDark[token.rawValue] = hex }
    }

    /// Fill a slot's custom colours from a built-in, so customising starts from something
    /// whole rather than from a blank set of wells.
    static func seedCustomColors(_ slot: ThemeSlot, from choice: ThemeChoice) {
        let source: Palette = choice == .ink ? .ink : .paper
        if slot == .light { shared.customLight = source.hexValues } else { shared.customDark = source.hexValues }
    }

    /// Make Downright the default app for Markdown files (the UTIs behind .md/.markdown).
    static func makeDefaultForMarkdown(completion: @escaping @MainActor (Error?) -> Void) {
        var types: [UTType] = []
        for ext in ["md", "markdown", "mdown", "mkd"] {
            if let t = UTType(filenameExtension: ext), !types.contains(t) { types.append(t) }
        }
        Task { @MainActor in
            var firstError: Error? = nil
            for type in types {
                let error: Error? = await withCheckedContinuation { cont in
                    NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { cont.resume(returning: $0) }
                }
                if firstError == nil { firstError = error }
            }
            completion(firstError)
        }
    }

    /// Match the app's own chrome — title bar, sheets, scrollers — to the page it frames.
    static func applyAppearance() {
        NSApp.appearance = selection.chrome
    }

    // MARK: - File

    /// Keys earlier versions wrote, dropped on the next save. `theme` and the flat
    /// `colors.<name>` are read once on the way out, in `migrateSingleTheme(_:)`.
    private static let retiredKeys: Set<String> = Set(["theme", "marker_color", "cursor_color"]
        + ColorToken.allCases.map { "colors.\($0.rawValue)" })

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
    # appearance: "system" (follow macOS) | "light" | "dark"
    # light_theme / dark_theme: what fills each slot — "paper" | "ink" | "custom"
    # colors.light.<name> / colors.dark.<name>: the Custom theme's colours for that slot,
    #   "#RRGGBB" or "#RRGGBBAA". Anything you leave out comes from that slot's own ground
    #   (Paper for light, Ink for dark). Names: background, text, secondary, faint, accent,
    #   marker, cursor, listMarker, rule, inlineCode, codeBlock, quote, quoteBar,
    #   frontmatter and
    #   code<Keyword|Type|String|Comment|Number|Key|Variable|Added|Removed|Meta|Tag|Attribute>.
    # copy_rich_text: when true, ⌘C copies formatted text and ⌘⇧C copies Markdown source
    # font_size: body text size in points (⌘+ / ⌘- / ⌘0 change it too)
    # max_content_width: widest text column in points; 0 uses the whole window

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
            // Writes only if the file differs from what this version reads — which is how
            // a file from before themes loses its retired keys.
            save()
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
        if case .string(let s)? = values["light_theme"], let c = ThemeChoice(rawValue: s) { lightTheme = c }
        if case .string(let s)? = values["dark_theme"], let c = ThemeChoice(rawValue: s) { darkTheme = c }
        if case .bool(let b)? = values["vim_mode"] { vimMode = b }
        if case .bool(let b)? = values["copy_rich_text"] { copyRichText = b }
        if case .int(let n)? = values["font_size"] { fontSize = Double(n) }
        if case .int(let n)? = values["max_content_width"] { maxContentWidth = Double(n) }
        customLight = Self.colors(in: values, prefix: "colors.light.")
        customDark = Self.colors(in: values, prefix: "colors.dark.")
        migrateSingleTheme(values)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The `#RRGGBBAA` values under a `colors.<slot>.` prefix, ignoring anything that is
    /// not a colour or not a token this version knows.
    private static func colors(in values: [String: TOMLValue], prefix: String) -> [String: String] {
        var out: [String: String] = [:]
        for token in ColorToken.allCases {
            if case .string(let hex)? = values[prefix + token.rawValue], Theme.color(hex: hex) != nil {
                out[token.rawValue] = hex
            }
        }
        return out
    }

    /// A file from the version that had one theme rather than two slots: `theme` picks
    /// the appearance and fills the matching slot, and its flat `colors.<name>` become
    /// that slot's custom set.
    private func migrateSingleTheme(_ values: [String: TOMLValue]) {
        guard values["light_theme"] == nil, values["dark_theme"] == nil,
              case .string(let theme)? = values["theme"] else { return }
        let flat = Self.colors(in: values, prefix: "colors.")
        switch theme {
        case "paper": appearance = .light; lightTheme = .paper
        case "ink": appearance = .dark; darkTheme = .ink
        case "custom":
            let dark = Palette.custom(flat).isDark
            appearance = dark ? .dark : .light
            if dark { darkTheme = .custom; customDark = flat } else { lightTheme = .custom; customLight = flat }
        default: appearance = .system   // "auto"
        }
    }

    private var values: [String: TOMLValue] {
        var v: [String: TOMLValue] = [
            "line_numbers": .bool(showLineNumbers),
            "outline": .bool(showOutline),
            "outline_collapsed": .bool(outlineCollapsed),
            "appearance": .string(appearance.rawValue),
            "light_theme": .string(lightTheme.rawValue),
            "dark_theme": .string(darkTheme.rawValue),
            "vim_mode": .bool(vimMode),
            "copy_rich_text": .bool(copyRichText),
            "font_size": .int(Int(fontSize.rounded())),
            "max_content_width": .int(Int(maxContentWidth.rounded())),
        ]
        // Custom colours are written only once there are some, so the built-ins can evolve.
        for (name, hex) in customLight { v["colors.light.\(name)"] = .string(hex) }
        for (name, hex) in customDark { v["colors.dark.\(name)"] = .string(hex) }
        return v
    }

    private func migrateFromUserDefaults() {
        let d = UserDefaults.standard
        suppressChanges = true
        defer { suppressChanges = false }
        if d.object(forKey: "showLineNumbers") != nil { showLineNumbers = d.bool(forKey: "showLineNumbers") }
        if d.object(forKey: "showOutline") != nil { showOutline = d.bool(forKey: "showOutline") }
        if d.object(forKey: "outlineCollapsed") != nil { outlineCollapsed = d.bool(forKey: "outlineCollapsed") }
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

    /// The leading comment block is the app's own documentation, so a file written by an
    /// older version is brought up to date with it rather than left describing settings
    /// that no longer exist. A file that does not start with our header is left alone.
    private static func refreshingHeader(_ text: String) -> String {
        guard text.hasPrefix("# Downright settings") else { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var end = 0
        while end < lines.count, lines[end].hasPrefix("#") { end += 1 }
        while end < lines.count, lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
        lines.removeSubrange(0..<end)
        let rest = lines.joined(separator: "\n")
        return rest.isEmpty ? header : header + "\n" + rest
    }

    /// Write the current values into the file, editing existing lines in place.
    func save() {
        let existing = Self.refreshingHeader((try? String(contentsOf: fileURL, encoding: .utf8)) ?? Self.header)
        let text = TOML.updating(existing, with: values, removing: Self.retiredKeys)
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

import AppKit
import DownrightEditor
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @State private var defaultStatus = ""
    @State private var expanded: Set<ColorToken.Group> = [.page]

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Theme", selection: themeBinding) {
                    ForEach(ThemePreset.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(themeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.themePreset == .custom {
                    HStack {
                        Text("Start over from")
                        Spacer()
                        Button("Paper") { Settings.seedCustomColors(from: .paper) }.controlSize(.small)
                        Button("Ink") { Settings.seedCustomColors(from: .ink) }.controlSize(.small)
                    }
                    ForEach(ColorToken.Group.allCases, id: \.self) { group in
                        DisclosureGroup(group.rawValue, isExpanded: expansion(of: group)) {
                            ForEach(ColorToken.allCases.filter { $0.group == group }, id: \.self) { token in
                                ColorPicker(token.title, selection: colorBinding(token), supportsOpacity: token.supportsOpacity)
                            }
                        }
                    }
                }
            }
            Section("Text") {
                HStack {
                    Text("Size")
                    Slider(value: $settings.fontSize, in: 9...32, step: 1)
                    Text("\(Int(settings.fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Reading width")
                    Slider(value: $settings.maxContentWidth, in: 0...1400, step: 20)
                    Text(settings.maxContentWidth == 0 ? "full" : "\(Int(settings.maxContentWidth)) pt").monospacedDigit().frame(width: 60, alignment: .trailing)
                }
                Text("Width limits the text column and centres it in wide windows; ⌘+ / ⌘− / ⌘0 change the size from the keyboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Editor") {
                Toggle("Show line numbers", isOn: $settings.showLineNumbers)
                Toggle("Show outline", isOn: $settings.showOutline)
            }
            Section("Copy") {
                Toggle("⌘C copies formatted text", isOn: $settings.copyRichText)
                Text(settings.copyRichText ? "⌘⇧C copies the Markdown source." : "⌘C copies the Markdown source; ⌘⇧C copies formatted text for pasting into mail, Slack or documents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Keys") {
                Toggle("Vim mode", isOn: $settings.vimMode)
                Text("Normal, insert, visual (v / V / ⌃V) and command modes with counts; d y c > < operators with motions, f/t finds and text objects (iw aw, quotes, brackets, ip ap); / ? n N search; . repeat; block I/A; ~ x D p P u ⌃R; :w :q :wq :q!.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Files") {
                HStack {
                    Text("Open .md files in Downright by default")
                    Spacer()
                    Button(defaultStatus.isEmpty ? "Make Default" : defaultStatus) {
                        Settings.makeDefaultForMarkdown { error in
                            defaultStatus = error == nil ? "Done ✓" : "Failed"
                        }
                    }
                    .controlSize(.small)
                }
            }
            Section {
                HStack {
                    Text("Stored in \(settings.displayPath)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([settings.fileURL])
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        // The custom theme's colour wells make this taller than a screen if it sizes to
        // its content, so the window keeps a height of its own and the form scrolls.
        .frame(width: 460, height: 620)
    }

    private var themeDescription: String {
        switch settings.themePreset {
        case .auto: return "Paper in daylight, Ink at night, following macOS."
        case .paper: return "A warm cream page with ink-brown text, always light."
        case .ink: return "The same palette at night: a warm dark ground, never flat grey."
        case .custom: return "Your own colours. Pick a starting point, then change what you like — the rest of the app follows the background."
        }
    }

    /// Switching to Custom seeds the wells from whatever is on screen now, so there is
    /// something whole to edit rather than a blank set.
    private var themeBinding: Binding<ThemePreset> {
        Binding(
            get: { settings.themePreset },
            set: { new in
                if new == .custom, settings.customColors.isEmpty {
                    Settings.seedCustomColors(from: settings.themePreset == .custom ? .paper : settings.themePreset)
                }
                settings.themePreset = new
            }
        )
    }

    private func colorBinding(_ token: ColorToken) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: Settings.palette[token]) },
            set: { settings.customColors[token.rawValue] = NSColor($0).hexString }
        )
    }

    private func expansion(of group: ColorToken.Group) -> Binding<Bool> {
        Binding(get: { expanded.contains(group) },
                set: { open in
                    if open { expanded.insert(group) } else { expanded.remove(group) }
                })
    }
}

/// Single shared Settings window (⌘,).
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

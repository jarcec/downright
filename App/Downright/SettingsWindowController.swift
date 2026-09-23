import AppKit
import DownrightEditor
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared
    @State private var defaultStatus = ""
    @State private var expanded: Set<ColorToken.Group> = [.page]
    @State private var editingSlot: ThemeSlot = .light

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Mode", selection: appearanceBinding) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Light theme", selection: choiceBinding(.light)) {
                    ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker("Dark theme", selection: choiceBinding(.dark)) {
                    ForEach(ThemeChoice.allCases) { Text($0.title).tag($0) }
                }
                Text(appearanceDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !customSlots.isEmpty {
                Section("Custom colours") {
                    if customSlots.count > 1 {
                        Picker("Editing", selection: $editingSlot) {
                            ForEach(ThemeSlot.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    HStack {
                        Text("Start over from")
                        Spacer()
                        Button("Paper") { Settings.seedCustomColors(slot, from: .paper) }.controlSize(.small)
                        Button("Ink") { Settings.seedCustomColors(slot, from: .ink) }.controlSize(.small)
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

    private var appearanceDescription: String {
        let light = settings.lightTheme.title, dark = settings.darkTheme.title
        switch settings.appearance {
        case .system: return "Follows macOS: \(light) in the light, \(dark) after dark."
        case .light: return "\(light), whatever macOS is set to."
        case .dark: return "\(dark), whatever macOS is set to."
        }
    }

    /// The slots set to Custom — the ones with colours to edit.
    private var customSlots: [ThemeSlot] {
        ThemeSlot.allCases.filter { Settings.selection.choice(for: $0) == .custom }
    }

    /// The slot the colour wells edit: the one being customised, or the chosen one when
    /// both are.
    private var slot: ThemeSlot { customSlots.contains(editingSlot) ? editingSlot : (customSlots.first ?? .light) }

    private var appearanceBinding: Binding<Appearance> {
        Binding(get: { settings.appearance },
                set: { settings.appearance = $0; Settings.applyAppearance() })
    }

    /// Choosing Custom for a slot seeds its wells from what that slot showed a moment
    /// ago, so there is something whole to edit rather than a blank set.
    private func choiceBinding(_ slot: ThemeSlot) -> Binding<ThemeChoice> {
        Binding(
            get: { Settings.selection.choice(for: slot) },
            set: { new in
                let previous = Settings.selection.choice(for: slot)
                if new == .custom, settings.custom(for: slot).isEmpty {
                    Settings.seedCustomColors(slot, from: previous == .custom ? (slot == .dark ? .ink : .paper) : previous)
                }
                if slot == .light { settings.lightTheme = new } else { settings.darkTheme = new }
                editingSlot = slot
                Settings.applyAppearance()
            }
        )
    }

    private func colorBinding(_ token: ColorToken) -> Binding<Color> {
        let slot = slot
        return Binding(
            get: { Color(nsColor: Settings.customPalette(for: slot)[token]) },
            set: { Settings.setCustom(NSColor($0).hexString, token: token, slot: slot) }
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

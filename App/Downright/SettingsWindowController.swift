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
                HStack {
                    Text("Mode")
                    Spacer()
                    ForEach(Appearance.allCases) { mode in
                        ModeButton(appearance: mode, selected: settings.appearance == mode, colors: colors) {
                            appearanceBinding.wrappedValue = mode
                        }
                    }
                }
                .padding(.vertical, 2)
                ForEach(visibleSlots) { slotRow($0) }
                Text(appearanceDescription)
                    .font(.caption)
                    .foregroundStyle(colors.secondary)
            }
            .listRowBackground(colors.surface)
            if !customSlots.isEmpty {
                Section("Custom colours \u{2014} \(slot.title)") {
                    if customSlots.count > 1 {
                        Picker("Editing", selection: $editingSlot) {
                            ForEach(ThemeSlot.allCases) { Text("\(Image(systemName: $0.symbol))  \($0.title)").tag($0) }
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
        .themedPanel(colors)
        // The custom theme's colour wells make this taller than a screen if it sizes to
        // its content, so the window keeps a height of its own and the form scrolls.
        .frame(width: 480, height: 640)
    }

    private var colors: ThemeColors { ThemeColors(Settings.theme.palette) }

    /// One slot and the three themes that can fill it, each showing its own colours.
    private func slotRow(_ slot: ThemeSlot) -> some View {
        HStack(alignment: .top) {
            Text("\(slot.title) theme")
            Spacer()
            ForEach(ThemeChoice.allCases) { choice in
                ThemeCard(choice: choice,
                          palette: preview(choice, in: slot),
                          selected: Settings.selection.choice(for: slot) == choice,
                          accent: colors.heading,
                          rule: colors.rule) {
                    choiceBinding(slot).wrappedValue = choice
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// What a card shows: the built-in itself, or the slot's own colours for Custom.
    private func preview(_ choice: ThemeChoice, in slot: ThemeSlot) -> Palette {
        switch choice {
        case .paper: return .paper
        case .ink: return .ink
        case .custom: return Settings.customPalette(for: slot)
        }
    }

    private var appearanceDescription: String {
        let light = settings.lightTheme.title, dark = settings.darkTheme.title
        switch settings.appearance {
        case .system: return "Follows macOS: \(light) in the light, \(dark) after dark."
        case .light: return "\(light), whatever macOS is set to. Switch to System to set a theme for the dark too."
        case .dark: return "\(dark), whatever macOS is set to. Switch to System to set a theme for the light too."
        }
    }

    /// The slots the mode can actually reach: both under System, otherwise just the one
    /// in force — there is no sense in configuring a theme that cannot appear.
    private var visibleSlots: [ThemeSlot] {
        switch settings.appearance {
        case .system: return ThemeSlot.allCases
        case .light: return [.light]
        case .dark: return [.dark]
        }
    }

    /// The reachable slots set to Custom — the ones with colours to edit.
    private var customSlots: [ThemeSlot] {
        visibleSlots.filter { Settings.selection.choice(for: $0) == .custom }
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
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Settings")
        super.init(window: window)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: Settings.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func themeChanged() { applyTheme() }

    /// The panel wears the theme, like the pages it configures.
    private func applyTheme() {
        window?.backgroundColor = Settings.theme.backgroundColor
        window?.appearance = Settings.selection.chrome
    }

    func show() {
        applyTheme()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

import AppKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(Settings.showLineNumbersKey) private var showLineNumbers = true
    @AppStorage(Settings.showOutlineKey) private var showOutline = true
    @AppStorage(Settings.appearanceKey) private var appearance = Settings.Appearance.system.rawValue
    @AppStorage(Settings.vimModeKey) private var vimMode = true

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Settings.Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            Section("Editor") {
                Toggle("Show line numbers", isOn: $showLineNumbers)
                Toggle("Show outline", isOn: $showOutline)
            }
            Section("Keys") {
                Toggle("Vim mode", isOn: $vimMode)
                Text("Normal/insert/command modes with counts, d y c operators, h j k l w b e 0 ^ $ G gg motions, x D p P u ⌃R, and :w :q :wq :q!.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
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

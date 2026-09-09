import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = Settings.shared

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(Settings.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
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
                Text("Normal, insert, visual (v / V / ⌃V) and command modes with counts; d y c > < operators with motions and text objects (iw aw, quotes, brackets, ip ap); ~ x D p P u ⌃R; :w :q :wq :q!.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(width: 420)
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

import AppKit
import DownrightEditor
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
                colorRow("Syntax markers", value: $settings.markerColor, fallback: Theme.defaultMarkerColor, supportsOpacity: false)
                colorRow("Vim cursor", value: $settings.cursorColor, fallback: Theme.defaultVimCursorColor, supportsOpacity: true)
                Text("Markers are the # and ** that appear on the caret's line; the vim cursor is the block shown in normal mode. Defaults are green, the cursor a lighter tone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Colour picker bound to an optional NSColor, with a Reset control when customised.
    private func colorRow(_ title: String, value: Binding<NSColor?>, fallback: NSColor, supportsOpacity: Bool) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(
                get: { Color(nsColor: value.wrappedValue ?? fallback) },
                set: { value.wrappedValue = NSColor($0) }
            ), supportsOpacity: supportsOpacity)
            if value.wrappedValue != nil {
                Button("Reset") { value.wrappedValue = nil }
                    .controlSize(.small)
            }
        }
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

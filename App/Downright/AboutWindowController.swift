import AppKit
import SwiftUI

struct AboutView: View {
    private var colors: ThemeColors { ThemeColors() }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Downright")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(colors.heading)
            Text("A Markdown editor that shows the document, not the syntax.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(colors.text)
            Text(version)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(colors.secondary)
                .textSelection(.enabled)
            Link("github.com/jarcec/downright", destination: URL(string: "https://github.com/jarcec/downright")!)
                .font(.caption)
                .foregroundStyle(colors.accent)
            Text("© 2026 Jaroslav Cecho")
                .font(.caption2)
                .foregroundStyle(colors.secondary)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: 340)
        .background(colors.background)
    }
}

/// Single shared About window, themed like the rest of the app rather than the standard
/// panel's system grey.
@MainActor
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
        window.title = "About Downright"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        super.init(window: window)
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: Settings.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func themeChanged() { applyTheme() }

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

import AppKit
import Foundation

/// User-visible settings, backed by `UserDefaults`. Observe
/// `UserDefaults.didChangeNotification` to react to changes from any source
/// (Settings window, View menu).
enum Settings {
    static let showLineNumbersKey = "showLineNumbers"
    static let showOutlineKey = "showOutline"
    static let outlineCollapsedKey = "outlineCollapsed"
    static let appearanceKey = "appearance"
    static let vimModeKey = "vimMode"

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

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showLineNumbersKey: true,
            showOutlineKey: true,
            outlineCollapsedKey: false,
            appearanceKey: Appearance.system.rawValue,
            vimModeKey: false,
        ])
    }

    static var showLineNumbers: Bool {
        get { UserDefaults.standard.bool(forKey: showLineNumbersKey) }
        set { UserDefaults.standard.set(newValue, forKey: showLineNumbersKey) }
    }

    static var showOutline: Bool {
        get { UserDefaults.standard.bool(forKey: showOutlineKey) }
        set { UserDefaults.standard.set(newValue, forKey: showOutlineKey) }
    }

    static var appearance: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: appearanceKey) }
    }

    /// Push the chosen appearance to the app. Safe to call repeatedly.
    @MainActor
    static func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    static var vimMode: Bool {
        get { UserDefaults.standard.bool(forKey: vimModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: vimModeKey) }
    }

    static var outlineCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: outlineCollapsedKey) }
        set { UserDefaults.standard.set(newValue, forKey: outlineCollapsedKey) }
    }
}

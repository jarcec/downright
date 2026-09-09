import Foundation

/// User-visible settings, backed by `UserDefaults`. Observe
/// `UserDefaults.didChangeNotification` to react to changes from any source
/// (Settings window, View menu).
enum Settings {
    static let showLineNumbersKey = "showLineNumbers"
    static let showOutlineKey = "showOutline"
    static let outlineCollapsedKey = "outlineCollapsed"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showLineNumbersKey: true,
            showOutlineKey: true,
            outlineCollapsedKey: false,
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

    static var outlineCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: outlineCollapsedKey) }
        set { UserDefaults.standard.set(newValue, forKey: outlineCollapsedKey) }
    }
}

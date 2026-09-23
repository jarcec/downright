import AppKit
import DownrightEditor
import SwiftUI

/// The theme's colours as SwiftUI values, for the windows that are not the editor: the
/// Settings and About panels. They take the same palette as the page, so the app is one
/// piece rather than a themed document in system-grey chrome.
struct ThemeColors {
    var palette: Palette

    init(_ palette: Palette) { self.palette = palette }
    @MainActor init() { self.palette = Settings.theme.palette }

    var background: Color { color(.background) }
    /// Cards and grouped rows: the palette's sunk/lifted surface.
    var surface: Color { color(.codeBlock) }
    var text: Color { color(.text) }
    var secondary: Color { color(.secondary) }
    var accent: Color { color(.accent) }
    var heading: Color { color(.heading) }
    var rule: Color { color(.rule) }

    func color(_ token: ColorToken) -> Color { Color(nsColor: palette[token]) }
}

extension View {
    /// Dress a panel in the theme: its own ground, its own accent, no system grey behind
    /// the form.
    func themedPanel(_ colors: ThemeColors) -> some View {
        self.scrollContentBackground(.hidden)
            .background(colors.background)
            // Controls take the theme's signature colour rather than the system accent,
            // so a toggle in Settings belongs to the same page as a heading.
            .tint(colors.heading)
            .foregroundStyle(colors.text)
    }
}

extension Appearance {
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

extension ThemeSlot {
    var symbol: String { self == .light ? "sun.max" : "moon" }
}

/// One appearance mode as an icon and a name. A segmented picker draws a Label's title
/// only, and the icon is the point of this row, so the control is built from buttons.
struct ModeButton: View {
    let appearance: Appearance
    let selected: Bool
    let colors: ThemeColors
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: appearance.symbol).font(.system(size: 15))
                Text(appearance.title).font(.caption)
            }
            .frame(width: 68, height: 46)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? colors.heading : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.clear : colors.rule, lineWidth: 1))
            .foregroundStyle(selected ? colors.background : colors.text)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A theme as a small sample of itself: the ground it draws on, its heading colour, and
/// dots for links and markers. Picking a theme for a slot is picking one of these.
struct ThemeCard: View {
    let choice: ThemeChoice
    let palette: Palette
    let selected: Bool
    let accent: Color
    let rule: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: palette[.background]))
                    HStack(spacing: 5) {
                        Text("Aa")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(nsColor: palette[.heading]))
                        Circle().fill(Color(nsColor: palette[.accent])).frame(width: 7, height: 7)
                        Circle().fill(Color(nsColor: palette[.marker])).frame(width: 7, height: 7)
                    }
                }
                .frame(width: 88, height: 42)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(selected ? accent : rule, lineWidth: selected ? 2 : 1)
                )
                Text(choice.title)
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .regular)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(choice.title) in this slot")
    }
}

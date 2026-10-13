import AppKit
import DownrightEditor

/// The window tab bar in the theme's colours.
///
/// AppKit draws the tab bar itself and offers nothing to colour it with, so the moment a
/// second file joined a window the warm page sat under a grey system strip. The bar is an
/// ordinary view tree in the titlebar of whichever tab is selected: this finds it,
/// recognises its parts by class name, and sets public properties on them — a glass view's
/// tint, a layer's colour. Nothing private is called, so an AppKit that builds the bar
/// differently finds nothing to dress and keeps the system's own colours rather than
/// breaking.
///
/// The tab titles, the close buttons and the + are drawn by the system from the app's
/// appearance, which already follows the theme (`ThemeSelection.chrome`), so they are
/// left alone: dark on a light theme, light on a dark one, like the window title itself.
@MainActor
enum TabBarChrome {
    /// Marks the view that carries the track's colour, so re-dressing the bar reuses it.
    private static let backingIdentifier = NSUserInterfaceItemIdentifier("DownrightTabBarBacking")

    /// Dress the tab bar this window is hosting, if it is hosting one. AppKit keeps the
    /// bar in the selected tab's window, so for every other window of a group — and for
    /// every untabbed window — this finds nothing and returns.
    static func apply(_ theme: Theme, to window: NSWindow?) {
        guard let window, let titlebar = window.contentView?.superview,
              let bar = titlebar.firstDescendant(ofClass: "NSTabBar") else { return }
        let palette = theme.palette

        // The track the tabs sit in takes the palette's other surface — sunk on paper,
        // lifted at night, the same one the outline and Settings cards use — so the strip
        // reads as part of the page rather than as a grey shelf above it. The track is
        // glass of a kind that is not public API and has no colour to set, so a plain view
        // carries the colour instead: over the glass, under the tabs, inside whichever
        // view holds them.
        let track = bar.firstDescendant(ofClass: "NSSubduedGlassEffectView")
            ?? bar.firstDescendant(ofClass: "NSTabBarTrackView") ?? bar
        if let host = track.subviews.first(where: { $0.firstDescendant(ofClass: "NSTabButton") != nil }) {
            let backing = host.subviews.first { $0.identifier == backingIdentifier } ?? {
                let view = NSView()
                view.identifier = backingIdentifier
                view.wantsLayer = true
                view.autoresizingMask = [.width, .height]
                host.addSubview(view, positioned: .below, relativeTo: nil)
                return view
            }()
            backing.frame = host.bounds
            backing.layer?.backgroundColor = palette[.codeBlock].resolved(in: host)
            backing.layer?.cornerRadius = host.bounds.height / 2
        }

        // Which tab is selected: each tab button says so itself, through the accessibility
        // value a radio button publishes — 1 for the chosen one. While a tab is animating
        // into place that can still be the old answer, so the group's own order stands in,
        // leading to trailing like the buttons.
        let tabs = bar.descendants(ofClass: "NSTabButton")
            .sorted { $0.convert(NSPoint.zero, to: bar).x < $1.convert(NSPoint.zero, to: bar).x }
        let selected = tabs.firstIndex { $0.accessibilityValue() as? Int == 1 }
            ?? window.tabGroup.flatMap { group in
                group.selectedWindow.flatMap { group.windows.firstIndex(of: $0) }
            }
        // The selected tab takes the page's own ground; the others stay clear and let the
        // track show through, which is the shape the system draws too.
        if #available(macOS 26.0, *) {
            for (index, tab) in tabs.enumerated() {
                guard let glass = tab.firstDescendant(ofClass: "NSGlassEffectView") as? NSGlassEffectView else { continue }
                glass.tintColor = index == selected ? palette[.background] : nil
            }
        }

        // The hairlines between unselected tabs.
        for separator in bar.descendants(ofClass: "NSTabSeparator") {
            separator.wantsLayer = true
            separator.layer?.backgroundColor = palette[.rule].resolved(in: separator)
        }
    }
}

private extension NSView {
    /// The first view of this exact class name anywhere below this one, depth first.
    func firstDescendant(ofClass name: String) -> NSView? {
        for view in subviews {
            if String(describing: type(of: view)) == name { return view }
            if let found = view.firstDescendant(ofClass: name) { return found }
        }
        return nil
    }

    /// Every view of this exact class name below this one. A match is not searched
    /// further: neither tabs nor separators nest.
    func descendants(ofClass name: String) -> [NSView] {
        subviews.flatMap { view -> [NSView] in
            String(describing: type(of: view)) == name ? [view] : view.descendants(ofClass: name)
        }
    }
}

private extension NSColor {
    /// This colour as the view draws it. A palette can be dynamic — one colour that is
    /// light by day and dark by night — and a layer wants a resolved value.
    func resolved(in view: NSView) -> CGColor {
        var out = cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { out = self.cgColor }
        return out
    }
}

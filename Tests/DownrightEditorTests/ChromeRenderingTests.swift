import XCTest
import AppKit
@testable import DownrightEditor

@MainActor
final class ChromeRenderingTests: XCTestCase {
    /// Builds the document-window layout (gutter | scroll, status bar below) and
    /// renders it; returns the count of dark sample pixels in the text area.
    private func inkWithStatusBar(_ includeStatusBar: Bool) -> Int {
        let storage = NSTextStorage(string: "# Title\nSome **bold** text here.\nmore lines\nand more\n")
        let c = EditorController(textStorage: storage)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let gutter = LineNumberGutterView(controller: c)
        let status = StatusBarView(frame: .zero)
        c.scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(gutter); container.addSubview(c.scrollView)
        var cons = [
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor), gutter.topAnchor.constraint(equalTo: container.topAnchor),
            c.scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor), c.scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            c.scrollView.topAnchor.constraint(equalTo: container.topAnchor),
        ]
        if includeStatusBar {
            container.addSubview(status)
            status.leadingText = "Ln 1"; status.trailingText = "GFM"
            cons += [status.leadingAnchor.constraint(equalTo: container.leadingAnchor), status.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                     status.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                     gutter.bottomAnchor.constraint(equalTo: status.topAnchor), c.scrollView.bottomAnchor.constraint(equalTo: status.topAnchor)]
        } else {
            cons += [gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor), c.scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)]
        }
        NSLayoutConstraint.activate(cons)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return -1 }
        container.cacheDisplay(in: container.bounds, to: rep)
        var dark = 0
        // Sample only the upper text area (skip the bottom 40px where the status bar lives)
        for y in stride(from: 0, to: Int(rep.pixelsHigh) - 80, by: 3) {
            for x in stride(from: 80, to: Int(rep.pixelsWide), by: 3) {
                if let col = rep.colorAt(x: x, y: y), col.brightnessComponent < 0.5 { dark += 1 }
            }
        }
        return dark
    }

    func testTextRendersWithoutStatusBar() {
        XCTAssertGreaterThan(inkWithStatusBar(false), 10)
    }

    func testTextRendersWithStatusBar() {
        XCTAssertGreaterThan(inkWithStatusBar(true), 10, "adding the status bar must not blank the text area")
    }
}

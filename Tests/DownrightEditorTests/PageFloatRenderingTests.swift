import XCTest
import AppKit
@testable import DownrightEditor

/// Chrome on the page (the outline in page mode): block backgrounds beside it stop where
/// it begins, and it stays above the text's own overlays.
@MainActor
final class PageFloatRenderingTests: XCTestCase {
    private func editor(_ text: String) -> (EditorController, NSWindow) {
        let c = EditorController(textStorage: NSTextStorage(string: text))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = window.contentView!.bounds
        window.layoutIfNeeded()
        return (c, window)
    }

    func testCodeBlockBackgroundStopsAtTheFloat() throws {
        let text = "Intro\n\n```\ncode line\n```\n\nafter\n"
        let (c, _) = editor(text)
        c.pageFloatSize = CGSize(width: 230, height: 150)
        let slot = try XCTUnwrap(c.pageFloatRect)
        c.scrollView.layoutSubtreeIfNeeded()
        let line = try XCTUnwrap(c.caretRect(at: (text as NSString).range(of: "code line").location))
        XCTAssertLessThan(line.maxY, slot.maxY, "the code line sits beside the float")

        let rep = try XCTUnwrap(c.scrollView.bitmapImageRepForCachingDisplay(in: c.scrollView.bounds))
        c.scrollView.cacheDisplay(in: c.scrollView.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / c.scrollView.bounds.width
        func color(x: CGFloat, y: CGFloat) -> NSColor? {
            let p = c.textView.convert(NSPoint(x: x, y: y), to: c.scrollView)
            return rep.colorAt(x: Int(p.x * scale), y: Int(p.y * scale))?.usingColorSpace(.sRGB)
        }
        func distance(_ a: NSColor?, _ b: NSColor?) -> CGFloat {
            guard let a, let b else { return .infinity }
            return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
        }
        let page = color(x: slot.minX + 40, y: slot.maxY + 150)   // bare page below everything
        let left = color(x: slot.minX - 60, y: line.midY), under = color(x: slot.minX + 40, y: line.midY)
        XCTAssertGreaterThan(distance(left, page), 0.05, "the block is tinted left of the float")
        XCTAssertLessThan(distance(under, page), 0.01, "but not under it")
    }

    func testChromeOnThePageStaysAboveTheSelection() {
        let (c, _) = editor("# Title\nbody\n")
        let chrome = NSView(frame: NSRect(x: 500, y: 24, width: 100, height: 40))
        c.textView.addSubview(chrome)
        c.textView.overlayViews = [chrome]
        c.textView.setSelectedRange(NSRange(location: 2, length: 3))   // re-stacks the selection overlay
        c.textView.layout()
        XCTAssertTrue(c.textView.subviews.last === chrome)
    }
}

@MainActor
final class OutlineModeButtonTests: XCTestCase {
    func testModeButtonTogglesAndHidesWhenCollapsed() {
        let o = OutlineOverlayView(frame: .zero)
        XCTAssertTrue(o.modeButton.isHidden, "no button until the host offers modes")
        var toggles = 0
        o.onToggleMode = { toggles += 1 }
        o.onPage = false
        XCTAssertFalse(o.modeButton.isHidden)
        XCTAssertEqual(o.modeButton.toolTip?.hasPrefix("Pinned"), true)
        o.modeButton.performClick(nil)
        XCTAssertEqual(toggles, 1)
        o.onPage = true
        XCTAssertEqual(o.modeButton.toolTip?.hasPrefix("On the page"), true)
        o.isCollapsed = true
        XCTAssertTrue(o.modeButton.isHidden, "the collapsed pill has no room for it")
        o.isCollapsed = false
        XCTAssertFalse(o.modeButton.isHidden)
    }
}

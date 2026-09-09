import XCTest
import AppKit
@testable import DownrightEditor

@MainActor
final class CaretGeometryTests: XCTestCase {
    /// Moving the caret across lines whose reveal state flips (heading ↔ empty line) must
    /// always yield a caret rectangle that sits inside its own paragraph fragment.
    func testCaretRectStaysValidAcrossRevealChanges() {
        let storage = NSTextStorage(string: "intro\n\n# Heading\nbody text\n\n```\ncode\n```\nend")
        let c = EditorController(textStorage: storage)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        window.layoutIfNeeded()
        window.makeFirstResponder(c.textView)

        c.textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        for step in 0..<12 {
            c.textView.moveUp(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            let sel = c.textView.selectedRange().location
            guard let rect = c.caretRect(at: sel) else { return XCTFail("no caret rect at \(sel) (step \(step))") }
            guard let loc = c.contentStorage.location(c.contentStorage.documentRange.location, offsetBy: sel),
                  let frag = c.layoutManager.textLayoutFragment(for: loc) else { return XCTFail("no fragment at \(sel)") }
            let fragInView = frag.layoutFragmentFrame.offsetBy(dx: c.textView.textContainerInset.width, dy: c.textView.textContainerInset.height)
            XCTAssertGreaterThan(rect.height, 0, "caret has no height at \(sel)")
            XCTAssertTrue(fragInView.insetBy(dx: -1, dy: -1).contains(CGPoint(x: rect.minX, y: rect.midY)),
                          "caret \(rect) outside fragment \(fragInView) at offset \(sel) (step \(step))")
        }
        XCTAssertEqual(c.textView.selectedRange().location, 0)
    }
}

import XCTest
import AppKit
@testable import DownrightEditor

@MainActor
final class TableHandlesTests: XCTestCase {
    func testHandlesAppearOverTableAndAddColumnRow() {
        let s = NSTextStorage(string: "intro\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nend\n")
        let c = EditorController(textStorage: s)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        window.layoutIfNeeded()
        let tv = c.textView

        // Over "intro": nothing
        tv.updateTableHandles(at: c.caretRect(at: 1).map { NSPoint(x: $0.midX, y: $0.midY) })
        XCTAssertFalse(tv.tableHandlesVisible)
        // Over the "1" cell: handles show
        let one = (s.string as NSString).range(of: "1").location
        tv.updateTableHandles(at: c.caretRect(at: one).map { NSPoint(x: $0.midX + 2, y: $0.midY) })
        XCTAssertTrue(tv.tableHandlesVisible)
        // Away: hidden again
        tv.updateTableHandles(at: nil)
        XCTAssertFalse(tv.tableHandlesVisible)
        // Buttons perform the operations
        tv.updateTableHandles(at: c.caretRect(at: one).map { NSPoint(x: $0.midX + 2, y: $0.midY) })
        tv.perform(NSSelectorFromString("handleAddColumn:"), with: nil)
        XCTAssertTrue(s.string.contains("| A | B |     |"), s.string)
        tv.updateTableHandles(at: c.caretRect(at: one).map { NSPoint(x: $0.midX + 2, y: $0.midY) })
        tv.perform(NSSelectorFromString("handleAddRow:"), with: nil)
        XCTAssertTrue(s.string.contains("| 1 | 2 |     |\n|     |     |     |\n\nend"), s.string)
        // View mode: no handles
        c.mode = .view
        tv.updateTableHandles(at: c.caretRect(at: one).map { NSPoint(x: $0.midX + 2, y: $0.midY) })
        XCTAssertFalse(tv.tableHandlesVisible)
    }
}

import XCTest
import AppKit
import MarkdownKit
@testable import DownrightEditor

/// A scrolled wide table keeps its first column where it was.
@MainActor
final class TablePinnedColumnTests: XCTestCase {
    func testAScrolledWideTableKeepsItsFirstColumnInPlace() {
        let wide = "Intro.\n\n| Item | Fact | Source |\n|---|---|---|\n| Legal name | Estuary Technologies, Inc.; the product was renamed from Estuary Flow to Estuary in March 2026 | [18] |\n| Founded | 2019 | [2] |\n\nOutro.\n"
        let c = EditorController(textStorage: NSTextStorage(string: wide))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        window.layoutIfNeeded()
        let ns = wide as NSString
        let start = ns.range(of: "| Item").location
        XCTAssertEqual(c.engine.tablePinnedWidth(blockStart: start), 0, "nothing pinned until it scrolls")
        c.scrollTable(blockStart: start, to: 150)
        let pin = c.engine.tablePinnedWidth(blockStart: start)
        XCTAssertGreaterThan(pin, 40)
        let g = try! XCTUnwrap(c.tableGeometry(blockStart: start))
        XCTAssertEqual(g.columnSpan(0)?.minX ?? 0, c.textView.textContainerInset.width, accuracy: 1, "the first column stays at the column's edge")
        XCTAssertEqual(g.left, c.textView.textContainerInset.width, accuracy: 1)
        let y = (g.rowEdges[1] + g.rowEdges[2]) / 2
        XCTAssertEqual(c.pinnedTable(at: NSPoint(x: g.left + pin / 2, y: y)), start, "a click there scrolls the table home first")
        XCTAssertNil(c.pinnedTable(at: NSPoint(x: g.left + pin + 30, y: y)))
        // The caret in a scrolled cell is kept clear of the pinned column.
        c.textView.setSelectedRange(NSRange(location: ns.range(of: "Estuary Technologies").location + 40, length: 0))
        let caret = c.caretRect(at: c.textView.selectedRange().location)!
        let pinned = c.engine.tablePinnedWidth(blockStart: start)
        XCTAssertGreaterThan(caret.minX, g.left + pinned)
    }
}

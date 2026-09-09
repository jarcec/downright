import XCTest
import AppKit
import MarkdownKit
@testable import DownrightEditor

@MainActor
final class TableOperationTests: XCTestCase {
    private var c: EditorController!
    private var s: NSTextStorage!
    private let src = "intro\n\n| A | B |\n|---|:-:|\n| 1 | 2 |\n| 3 | 4 |\n\nend\n"
    override func setUp() {
        s = NSTextStorage(string: src)
        c = EditorController(textStorage: s)
        c.layoutManager.textContainer?.size = CGSize(width: 800, height: 1e7)
    }
    private func at(_ needle: String) -> Int { (s.string as NSString).range(of: needle).location }
    private var selText: String { (s.string as NSString).substring(with: c.textView.selectedRange()) }

    func testInsertColumnRightAndLeft() {
        XCTAssertTrue(c.performTableOperation(.insertColumnRight, at: at("A")))
        XCTAssertEqual(s.string, "intro\n\n| A |     | B |\n|---|---|:-:|\n| 1 |     | 2 |\n| 3 |     | 4 |\n\nend\n")
        XCTAssertEqual(c.textView.selectedRange().length, 0, "caret lands in the new (empty) header cell")
        XCTAssertEqual(c.tableHit(at: c.textView.selectedRange().location)?.cellIndex, 1)
        XCTAssertTrue(c.performTableOperation(.insertColumnLeft, at: at("A")))
        XCTAssertTrue(s.string.hasPrefix("intro\n\n|     | A |     | B |\n|---|---|---|:-:|\n"), "got: \(s.string.debugDescription)")
    }

    func testDeleteColumnKeepsAlignmentOfOthers() {
        XCTAssertTrue(c.performTableOperation(.deleteColumn, at: at("A")))
        XCTAssertEqual(s.string, "intro\n\n| B |\n|:-:|\n| 2 |\n| 4 |\n\nend\n")
        XCTAssertFalse(c.canPerformTableOperation(.deleteColumn, at: at("B")), "last column cannot be deleted")
    }

    func testRowsInsertDeleteMove() {
        XCTAssertTrue(c.performTableOperation(.insertRowBelow, at: at("1")))
        XCTAssertEqual(s.string, "intro\n\n| A | B |\n|---|:-:|\n| 1 | 2 |\n|     |     |\n| 3 | 4 |\n\nend\n")
        XCTAssertEqual(c.tableHit(at: c.textView.selectedRange().location)?.rowIndex, 2)
        XCTAssertTrue(c.performTableOperation(.deleteRow, at: c.textView.selectedRange().location))
        XCTAssertEqual(s.string, src)
        XCTAssertTrue(c.performTableOperation(.moveRowDown, at: at("1")))
        XCTAssertEqual(s.string, "intro\n\n| A | B |\n|---|:-:|\n| 3 | 4 |\n| 1 | 2 |\n\nend\n")
        XCTAssertFalse(c.canPerformTableOperation(.deleteRow, at: at("A")), "header row stays")
        XCTAssertTrue(c.performTableOperation(.insertRowAbove, at: at("A")))
        XCTAssertTrue(s.string.contains("|---|:-:|\n|     |     |\n| 3 | 4 |"), "above the header means first body row")
    }

    func testMoveColumnAndAlign() {
        XCTAssertTrue(c.performTableOperation(.moveColumnRight, at: at("A")))
        XCTAssertEqual(s.string, "intro\n\n| B | A |\n|:-:|---|\n| 2 | 1 |\n| 4 | 3 |\n\nend\n")
        XCTAssertTrue(c.performTableOperation(.align(.right), at: at("B")))
        XCTAssertTrue(s.string.contains("|--:|---|"))
        XCTAssertEqual(c.tableColumnAlignment(at: at("B")), .right)
        XCTAssertTrue(c.performTableOperation(.align(.none), at: at("B")))
        XCTAssertTrue(s.string.contains("|---|---|"))
    }

    func testRaggedRowsGetPaddedAndPipelessStyleKept() {
        s.replaceCharacters(in: NSRange(location: 0, length: s.length), with: "A | B\n--|--\n1\n")
        c.reparseAll()
        XCTAssertTrue(c.performTableOperation(.insertColumnRight, at: 4))   // at "B"
        XCTAssertEqual(s.string, "A | B |    \n--|--|---\n1 |     |    \n")
    }

    func testMenuValidationOutsideTable() {
        XCTAssertFalse(c.canPerformTableOperation(.insertRowBelow, at: 0))
    }
}

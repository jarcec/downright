import XCTest
import AppKit
import MarkdownKit
@testable import DownrightEditor

/// Moving, copying, duplicating and sorting by position — what the grips and the toolbar
/// drive.
@MainActor
final class TableTargetOperationTests: XCTestCase {
    private var c: EditorController!
    private var s: NSTextStorage!
    private let src = "intro\n\n| A | B | C |\n|---|:-:|---|\n| 1 | b | x |\n| 2 | a | y |\n| 10 | c | z |\n\nend\n"
    private let start = 7   // after "intro\n\n"

    override func setUp() {
        s = NSTextStorage(string: src)
        c = EditorController(textStorage: s)
        c.layoutManager.textContainer?.size = CGSize(width: 800, height: 1e7)
    }

    private func target(row: Int, column: Int = 0) -> EditorController.TableTarget { .init(blockStart: start, row: row, column: column) }

    func testMoveARowToAnyGap() {
        // Row "10" (allRows index 3) to just under the header.
        let r = c.performTableOperation(.moveRow(to: 1), on: target(row: 3))
        XCTAssertEqual(r?.row, 1)
        XCTAssertTrue(s.string.contains("|---|:-:|---|\n| 10 | c | z |\n| 1 | b | x |\n| 2 | a | y |\n"), s.string)
        // And down to the end.
        XCTAssertEqual(c.performTableOperation(.moveRow(to: 4), on: target(row: 1))?.row, 3)
        XCTAssertTrue(s.string.contains("| 1 | b | x |\n| 2 | a | y |\n| 10 | c | z |\n"), s.string)
        // Dropping a row where it is does nothing; the header does not move.
        XCTAssertFalse(c.canPerformTableOperation(.moveRow(to: 2), on: target(row: 2)))
        XCTAssertFalse(c.canPerformTableOperation(.moveRow(to: 2), on: target(row: 0)))
    }

    func testCopyARowAndDuplicateIt() {
        XCTAssertEqual(c.performTableOperation(.copyRow(to: 4), on: target(row: 1))?.row, 4)
        XCTAssertTrue(s.string.contains("| 10 | c | z |\n| 1 | b | x |\n\nend"), s.string)
        XCTAssertEqual(c.performTableOperation(.duplicateRow, on: target(row: 2))?.row, 3)
        XCTAssertTrue(s.string.contains("| 2 | a | y |\n| 2 | a | y |\n"), s.string)
    }

    func testMoveAndCopyAColumnWithItsAlignment() {
        XCTAssertEqual(c.performTableOperation(.moveColumn(to: 0), on: target(row: 0, column: 1))?.column, 0)
        XCTAssertTrue(s.string.contains("| B | A | C |\n|:-:|---|---|\n| b | 1 | x |"), s.string)
        XCTAssertEqual(c.performTableOperation(.copyColumn(to: 3), on: target(row: 0, column: 0))?.column, 3)
        XCTAssertTrue(s.string.contains("| B | A | C | B |\n|:-:|---|---|:-:|\n| b | 1 | x | b |"), s.string)
    }

    func testSortByAColumnComparesNumbersByValue() {
        XCTAssertEqual(c.tableSortOrder(blockStart: start, column: 0), true, "1, 2, 10 is already A to Z")
        c.performTableOperation(.sort(ascending: true), on: target(row: 0, column: 1))
        XCTAssertTrue(s.string.contains("| 2 | a | y |\n| 1 | b | x |\n| 10 | c | z |"), s.string)
        XCTAssertEqual(c.tableSortOrder(blockStart: start, column: 1), true)
        c.performTableOperation(.sort(ascending: false), on: target(row: 0, column: 0))
        XCTAssertTrue(s.string.contains("| 10 | c | z |\n| 2 | a | y |\n| 1 | b | x |"), s.string)
        XCTAssertEqual(c.tableSortOrder(blockStart: start, column: 0), false)
    }
}

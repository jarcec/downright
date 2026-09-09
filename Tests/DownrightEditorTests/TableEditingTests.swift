import XCTest
import AppKit
@testable import DownrightEditor

@MainActor
final class TableEditingTests: XCTestCase {
    private let src = "| Name | **Amount** |\n|---|---:|\n| a | 1 |\n| b | **2** |\n\nafter\n"
    private var c: EditorController!
    private var storage: NSTextStorage!

    override func setUp() {
        storage = NSTextStorage(string: src)
        c = EditorController(textStorage: storage)
        c.layoutManager.textContainer?.size = CGSize(width: 800, height: 1e7)
    }

    private func sel(_ loc: Int) { c.textView.setSelectedRange(NSRange(location: loc, length: 0)) }
    private var caret: Int { c.textView.selectedRange().location }
    private func text(_ r: NSRange) -> String { (storage.string as NSString).substring(with: r) }

    func testHitTesting() {
        let h = c.tableHit(at: 2)!            // "Name"
        XCTAssertEqual(h.rowIndex, 0); XCTAssertEqual(h.cellIndex, 0)
        XCTAssertNil(c.tableHit(at: 0)?.cellIndex, "on the leading pipe: no cell")
        XCTAssertTrue(c.isOnTableDelimiter(23))
        XCTAssertNil(c.tableHit(at: src.utf16.count - 3), "'after' is not in the table")
    }

    func testTabMovesAcrossCells() {
        sel(2)
        XCTAssertTrue(c.tableTab(at: caret, forward: true))
        XCTAssertEqual(text(c.textView.selectedRange()), "**Amount**")
        XCTAssertTrue(c.tableTab(at: caret, forward: true))
        XCTAssertEqual(text(c.textView.selectedRange()), "a", "wraps to the first body row, skipping the delimiter")
        XCTAssertTrue(c.tableTab(at: caret, forward: false))
        XCTAssertEqual(text(c.textView.selectedRange()), "**Amount**")
    }

    func testReturnInsertsRow() {
        sel(2)   // header → new row goes below the delimiter
        XCTAssertTrue(c.tableInsertRow(at: caret))
        XCTAssertEqual(storage.string, "| Name | **Amount** |\n|---|---:|\n|   |   |\n| a | 1 |\n| b | **2** |\n\nafter\n")
        XCTAssertEqual(caret, 35)
        // Body row
        let bStart = (storage.string as NSString).range(of: "| b |").location + 2
        sel(bStart)
        XCTAssertTrue(c.tableInsertRow(at: caret))
        XCTAssertTrue(storage.string.contains("| b | **2** |\n|   |   |\n\nafter"))
    }

    func testCaretSnapsOverSeparators() {
        sel(6)   // end of "Name"
        c.textView.moveRight(nil)
        XCTAssertEqual(caret, 9, "skips ' | ' to the start of **Amount**")
        c.textView.moveLeft(nil)
        XCTAssertEqual(caret, 6, "and back to the end of Name")
    }

    func testMoveDownSkipsDelimiterRow() {
        sel(2)
        c.textView.moveDown(nil)
        XCTAssertFalse(c.isOnTableDelimiter(caret))
        XCTAssertEqual(c.tableHit(at: caret)?.rowIndex, 1)
    }

    func testOnlyCaretCellRevealsMarkers() {
        // Caret in "a" (row 1, cell 0): "**2**" markers in row 2 stay hidden; header markers hidden.
        sel(35)
        func fontSize(at offset: Int) -> CGFloat {
            let pr = c.lines.paragraphRange(ofLine: c.lines.line(containing: offset))
            let para = c.contentStorage.delegate!.textContentStorage!(c.contentStorage, textParagraphWith: pr)!
            let a = para.attributedString
            return (a.attribute(.font, at: offset - pr.location, effectiveRange: nil) as! NSFont).pointSize
        }
        let amountMarkers = (src as NSString).range(of: "**Amount**").location
        XCTAssertLessThan(fontSize(at: amountMarkers), 1, "header markers concealed while caret elsewhere")
        let two = (src as NSString).range(of: "**2**").location
        XCTAssertLessThan(fontSize(at: two), 1)
        // Move into the "**2**" cell: its markers show, the header's still hidden
        sel(two + 2)
        XCTAssertGreaterThan(fontSize(at: two), 1, "caret cell reveals its markers")
        XCTAssertLessThan(fontSize(at: amountMarkers), 1)
        // Pipes never reveal
        let pipe = (src as NSString).range(of: "| b |").location
        XCTAssertLessThan(fontSize(at: pipe), 1)
        XCTAssertEqual(c.engine.revealedCell?.cellIndex, 1)
    }
}

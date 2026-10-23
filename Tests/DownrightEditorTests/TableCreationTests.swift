import XCTest
import AppKit
import MarkdownKit
@testable import DownrightEditor

/// Insert Table, a typed header row, pasted cells.
@MainActor
final class TableCreationTests: XCTestCase {
    private func make(_ text: String) -> (EditorController, NSTextStorage) {
        let s = NSTextStorage(string: text)
        let c = EditorController(textStorage: s)
        c.layoutManager.textContainer?.size = CGSize(width: 800, height: 1e7)
        return (c, s)
    }

    func testInsertTableGoesOnItsOwnLinesWithTheCaretInTheFirstCell() {
        let (c, s) = make("Who starts in November\nNext paragraph\n")
        c.textView.setSelectedRange(NSRange(location: 22, length: 0))   // end of the first line
        XCTAssertTrue(c.insertTable(columns: 3, rows: 2))
        XCTAssertEqual(s.string, "Who starts in November\n\n|     |     |     |\n|---|---|---|\n|     |     |     |\n\nNext paragraph\n")
        let h = c.tableHit(at: c.textView.selectedRange().location)
        XCTAssertEqual(h?.rowIndex, 0)
        XCTAssertEqual(h?.cellIndex, 0)
    }

    func testReturnAfterATypedHeaderMakesATable() {
        let (c, s) = make("Team\n\n| Name | Role | Start |")
        c.textView.setSelectedRange(NSRange(location: s.length, length: 0))
        c.textView.insertNewline(nil)
        XCTAssertEqual(s.string, "Team\n\n| Name | Role | Start |\n|---|---|---|\n|     |     |     |")
        let h = c.tableHit(at: c.textView.selectedRange().location)
        XCTAssertEqual(h?.rowIndex, 1, "the caret waits in the first body cell")
        XCTAssertEqual(h?.cellIndex, 0)
        // Not inside code.
        let (code, cs) = make("```\n| a | b |\n```\n")
        code.textView.setSelectedRange(NSRange(location: 13, length: 0))   // end of "| a | b |"
        code.textView.insertNewline(nil)
        XCTAssertEqual(cs.string, "```\n| a | b |\n\n```\n")
    }

    func testPastedSpreadsheetCellsBecomeATableOrFillOne() {
        let (c, s) = make("Intro\n")
        c.textView.setSelectedRange(NSRange(location: 5, length: 0))
        let pb = NSPasteboard(name: NSPasteboard.Name("downright-test-\(UUID().uuidString)"))
        pb.declareTypes([.string], owner: nil)
        pb.setString("Name\tRole\nDana\tOps | Infra\nPriya\tDesign\n", forType: .string)
        c.mode = .live
        XCTAssertTrue(c.pasteTableCells(from: pb))
        XCTAssertEqual(s.string, "Intro\n\n| Name | Role |\n|---|---|\n| Dana | Ops \\| Infra |\n| Priya | Design |\n", s.string.debugDescription)
        // Inside the table: fills from the caret, adding a row at the end.
        let dana = (s.string as NSString).range(of: "Priya").location
        c.textView.setSelectedRange(NSRange(location: dana, length: 0))
        pb.declareTypes([MarkdownTextView.tabSeparatedType], owner: nil)
        pb.setString("Marco\tSales\nAda\tEng\n", forType: MarkdownTextView.tabSeparatedType)
        XCTAssertTrue(c.pasteTableCells(from: pb))
        XCTAssertEqual(s.string, "Intro\n\n| Name | Role |\n|---|---|\n| Dana | Ops \\| Infra |\n| Marco | Sales |\n| Ada | Eng |\n")
        // A single line with a tab is just text.
        pb.declareTypes([.string], owner: nil)
        pb.setString("a\tb", forType: .string)
        XCTAssertNil(EditorController.pastedCells(from: pb))
        pb.releaseGlobally()
    }

    func testCellsFromAWebPageTable() {
        let html = "<html><body><table><tr><th>City</th><th>Pop</th></tr><tr><td>Brno</td><td>400k</td></tr></table></body></html>"
        XCTAssertEqual(EditorController.grid(fromHTML: Data(html.utf8)), [["City", "Pop"], ["Brno", "400k"]])
    }
}

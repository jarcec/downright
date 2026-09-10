import XCTest
import AppKit
@testable import DownrightEditor

@MainActor
final class FoldingTests: XCTestCase {
    private let src = "---\nt: 1\n---\n# A\na1\na2\n## A.1\nsub\n# B\nb1\n"
    //                lines: 0 ---,1 t,2 ---,3 #A,4 a1,5 a2,6 ##A.1,7 sub,8 #B,9 b1,10 phantom
    private var c: EditorController!
    private var s: NSTextStorage!
    override func setUp() {
        s = NSTextStorage(string: src)
        c = EditorController(textStorage: s)
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
    }
    private func heights() -> [Int: CGFloat] {
        var h: [Int: CGFloat] = [:]
        c.layoutManager.enumerateTextLayoutFragments(from: c.layoutManager.documentRange.location, options: [.ensuresLayout]) { f in
            let loc = c.contentStorage.offset(from: c.contentStorage.documentRange.location, to: f.textElement!.elementRange!.location)
            h[c.lines.line(containing: loc)] = f.layoutFragmentFrame.height; return true
        }
        return h
    }

    func testFoldHeadingHidesSectionUntilPeer() {
        XCTAssertNotNil(c.foldableBlock(atLine: 3)); XCTAssertNil(c.foldableBlock(atLine: 4))
        c.toggleFold(atLine: 3)   // # A → hides a1, a2, ## A.1, sub (until # B)
        XCTAssertEqual(c.engine.hiddenLines, [4, 5, 6, 7])
        let h = heights()
        XCTAssertEqual(h[4], 0); XCTAssertEqual(h[7], 0)
        XCTAssertGreaterThan(h[8]!, 10, "# B stays visible")
        c.toggleFold(atLine: 3)
        XCTAssertTrue(c.engine.hiddenLines.isEmpty)
    }

    func testFrontmatterFoldKeepsFirstLine() {
        c.toggleFold(atLine: 0)
        XCTAssertEqual(c.engine.hiddenLines, [1, 2])
    }

    func testCaretSkipsHiddenLinesAndSectionFoldFromInside() {
        c.textView.setSelectedRange(NSRange(location: 22, length: 0))   // inside "a2"
        c.foldSection(containing: 22)                                    // folds # A
        XCTAssertEqual(c.foldedBlocks, [13])
        XCTAssertFalse(c.isLineHidden(c.lines.line(containing: c.textView.selectedRange().location)), "caret moved out of the hidden text")
        c.textView.setSelectedRange(NSRange(location: 13, length: 0))    // on # A
        c.textView.moveDown(nil)
        XCTAssertEqual(c.lines.line(containing: c.textView.selectedRange().location), 8, "↓ lands on # B, skipping the folded section")
        c.textView.moveUp(nil)
        XCTAssertEqual(c.lines.line(containing: c.textView.selectedRange().location), 3)
    }

    func testFoldsFollowEditsAndUnfoldOnJump() {
        c.toggleFold(atLine: 8)   // # B
        XCTAssertEqual(c.foldedBlocks, [34])
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        c.textView.insertText("intro\n\n", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(c.foldedBlocks, [41], "anchor shifted by the inserted text")
        XCTAssertTrue(c.isLineHidden(c.lines.line(containing: 41 + 4)))
        c.scroll(to: 41 + 4)      // jumping into the fold unfolds it
        XCTAssertTrue(c.foldedBlocks.isEmpty)
    }
}

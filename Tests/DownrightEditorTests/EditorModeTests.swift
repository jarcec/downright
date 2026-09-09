import XCTest
import AppKit
@testable import DownrightEditor

@MainActor
final class EditorModeTests: XCTestCase {
    private func make() -> (EditorController, NSTextStorage) {
        let s = NSTextStorage(string: "# Title\nSome **bold** text.\n- item\n")
        let c = EditorController(textStorage: s)
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        c.textView.setSelectedRange(NSRange(location: 20, length: 0))   // in the paragraph line
        return (c, s)
    }
    private func paragraph(_ c: EditorController, at offset: Int) -> NSAttributedString {
        let pr = c.lines.paragraphRange(ofLine: c.lines.line(containing: offset))
        return c.contentStorage.delegate!.textContentStorage!(c.contentStorage, textParagraphWith: pr)!.attributedString
    }
    private func fontSize(_ a: NSAttributedString, _ i: Int) -> CGFloat { (a.attribute(.font, at: i, effectiveRange: nil) as! NSFont).pointSize }

    func testLiveIsDefaultAndConcealsOtherLines() {
        let (c, _) = make()
        XCTAssertEqual(c.mode, .live)
        XCTAssertTrue(c.textView.isEditable)
        let heading = paragraph(c, at: 0)
        XCTAssertLessThan(fontSize(heading, 0), 1, "'#' concealed while the caret is elsewhere")
        XCTAssertGreaterThan(fontSize(heading, 2), 20, "heading typography")
        let para = paragraph(c, at: 8)
        XCTAssertGreaterThan(fontSize(para, 5), 1, "caret line reveals its ** markers")
    }

    func testRawShowsSourceInMonospace() {
        let (c, _) = make()
        c.mode = .raw
        let heading = paragraph(c, at: 0)
        XCTAssertGreaterThan(fontSize(heading, 0), 1, "'#' visible")
        XCTAssertEqual(fontSize(heading, 0), fontSize(heading, 2), "no heading size in raw mode")
        XCTAssertTrue((heading.attribute(.font, at: 2, effectiveRange: nil) as! NSFont).fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual((heading.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.hexString, c.theme.markerColor.hexString, "markers tinted")
        XCTAssertTrue(c.textView.isEditable)
        XCTAssertTrue(c.revealAll)
    }

    func testViewRendersEverythingAndIsReadOnly() {
        let (c, s) = make()
        c.mode = .view
        XCTAssertFalse(c.textView.isEditable)
        XCTAssertTrue(c.textView.isSelectable)
        let para = paragraph(c, at: 8)   // caret line, yet nothing reveals
        XCTAssertLessThan(fontSize(para, 5), 1, "markers stay concealed in view mode even on the caret line")
        let heading = paragraph(c, at: 0)
        XCTAssertGreaterThan(fontSize(heading, 2), 20)
        // Edits are refused
        c.textView.insertText("X", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(s.string, "# Title\nSome **bold** text.\n- item\n")
        // Back to live: editable again and reveal resumes
        c.mode = .live
        XCTAssertTrue(c.textView.isEditable)
        XCTAssertGreaterThan(fontSize(paragraph(c, at: 8), 5), 1)
    }

    func testToggleRawKeepsLegacyShortcutSemantics() {
        let (c, _) = make()
        var changes: [EditorController.Mode] = []
        c.onModeChange = { changes.append($0) }
        c.revealAll = true; XCTAssertEqual(c.mode, .raw)
        c.revealAll = false; XCTAssertEqual(c.mode, .live)
        XCTAssertEqual(changes, [.raw, .live])
    }
}

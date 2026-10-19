import XCTest
import AppKit
@testable import DownrightEditor

@MainActor
final class LinkTests: XCTestCase {
    private let dir = URL(fileURLWithPath: "/tmp/downright-links", isDirectory: true)

    private func make(_ text: String, titled: Bool = true) -> EditorController {
        let c = EditorController(textStorage: NSTextStorage(string: text))
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        if titled { c.baseURL = dir.appendingPathComponent("doc.md") }
        return c
    }

    private func link(_ c: EditorController, line: Int = 0, at i: Int = 1) -> URL? {
        let pr = c.lines.paragraphRange(ofLine: line)
        let a = c.contentStorage.delegate!.textContentStorage!(c.contentStorage, textParagraphWith: pr)!.attributedString
        return a.attribute(.link, at: i, effectiveRange: nil) as? URL
    }

    // MARK: - Resolution

    func testWebLinkKeepsItsURL() {
        XCTAssertEqual(link(make("[x](https://example.com/a?b=1)"))?.absoluteString, "https://example.com/a?b=1")
        XCTAssertEqual(link(make("see <https://example.com>"), at: 6)?.absoluteString, "https://example.com")
        XCTAssertEqual(link(make("[f](file:///tmp/x/../a.md#top)"))?.absoluteString, "file:///tmp/a.md#top")
        XCTAssertEqual(link(make("[m](mailto:a@b.c)"))?.absoluteString, "mailto:a@b.c")
    }

    func testRelativePathResolvesAgainstTheDocument() {
        let u = link(make("[notes](../notes/other.md)"))
        XCTAssertEqual(u?.path, "/tmp/notes/other.md")
        XCTAssertTrue(u?.isFileURL == true)
        XCTAssertEqual(link(make("[a](sub/a%20b.md)"))?.path, "/tmp/downright-links/sub/a b.md")
        XCTAssertEqual(link(make("[a](/abs/a.md)"))?.path, "/abs/a.md")
    }

    func testFragmentSurvivesResolution() {
        let u = link(make("[a](other.md#setup)"))
        XCTAssertEqual(u?.path, "/tmp/downright-links/other.md")
        XCTAssertEqual(u?.fragment, "setup")
    }

    func testAnchorIsASchemelessFragment() {
        let u = link(make("[a](#my-heading)"))
        XCTAssertNil(u?.scheme)
        XCTAssertEqual(u?.fragment, "my-heading")
        XCTAssertEqual(link(make("[a](#my-heading)", titled: false))?.fragment, "my-heading", "anchors need no file")
    }

    func testRelativePathInUntitledDocumentIsNotALink() {
        XCTAssertNil(link(make("[a](other.md)", titled: false)))
        XCTAssertNil(link(make("[a](notascheme:thing)", titled: false)), "unknown schemes stay inert")
    }

    func testRenamingTheDocumentRebindsLinks() {
        let c = make("[a](other.md)")
        XCTAssertEqual(link(c)?.path, "/tmp/downright-links/other.md")
        c.baseURL = URL(fileURLWithPath: "/tmp/elsewhere/doc.md")
        XCTAssertEqual(link(c)?.path, "/tmp/elsewhere/other.md")
    }

    // MARK: - Following

    func testAppClaimsLinksFirst() {
        let c = make("[a](other.md)")
        var seen: URL?
        c.onOpenLink = { seen = $0; return true }
        c.open(link(c)!)
        XCTAssertEqual(seen?.path, "/tmp/downright-links/other.md")
    }

    func testAnchorJumpsToItsHeading() {
        let c = make("# Top\n\ntext [go](#setup-notes)\n\n## Setup Notes!\n\nmore\n")
        var claimed = false
        c.onOpenLink = { _ in claimed = true; return true }
        c.open(link(c, line: 2, at: 6)!)
        XCTAssertFalse(claimed, "anchors are the editor's own")
        XCTAssertEqual(c.textView.selectedRange().location, (c.textStorage.string as NSString).range(of: "## Setup").location)
        XCTAssertFalse(c.scroll(toHeading: "missing"))
    }

    func testLinkLookupAndTheCaretRule() {
        let c = make("plain [a](other.md) text\n\nsecond\n")
        XCTAssertNil(c.link(atOffset: 0))
        XCTAssertEqual(c.link(atOffset: 7)?.path, "/tmp/downright-links/other.md", "inside the link text")
        XCTAssertEqual(c.link(atOffset: 14)?.path, "/tmp/downright-links/other.md", "inside the destination")
        XCTAssertNil(c.link(atOffset: 21))
        c.textView.setSelectedRange(NSRange(location: 27, length: 0))   // caret in "second"
        XCTAssertTrue(c.plainClickFollowsLink(at: 7))
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))    // caret in the link's paragraph
        XCTAssertFalse(c.plainClickFollowsLink(at: 7))
        c.mode = .view
        XCTAssertTrue(c.plainClickFollowsLink(at: 7), "read-only: every click follows")
    }

    func testSlug() {
        XCTAssertEqual(EditorController.slug("Setup Notes!"), "setup-notes")
        XCTAssertEqual(EditorController.slug("A  B"), "a--b")
        XCTAssertEqual(EditorController.slug("Déjà vu_2"), "déjà-vu_2")
    }
}

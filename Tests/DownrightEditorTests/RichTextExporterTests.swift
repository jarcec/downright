import XCTest
import AppKit
@testable import DownrightEditor

@MainActor
final class RichTextExporterTests: XCTestCase {
    func testStructureAndAttributes() {
        let md = "# Title\n\nSome **bold** and `code` with a [link](https://x.y).\n\n- one\n- [x] two\n\n```\nlet a = 1\n```\n"
        let a = RichTextExporter.attributedString(markdown: md)
        let s = a.string
        XCTAssertEqual(s, "Title\nSome bold and code with a link.\n•  one\n•  ☑ two\nlet a = 1")
        func font(at sub: String) -> NSFont { a.attribute(.font, at: (s as NSString).range(of: sub).location, effectiveRange: nil) as! NSFont }
        XCTAssertGreaterThan(font(at: "Title").pointSize, font(at: "Some").pointSize)
        XCTAssertTrue(font(at: "bold").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(font(at: "Some").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(font(at: "code").fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual((a.attribute(.link, at: (s as NSString).range(of: "link").location, effectiveRange: nil) as? URL)?.absoluteString, "https://x.y")
        XCTAssertTrue(font(at: "let a").fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    func testTablesBecomeTabSeparated() {
        let a = RichTextExporter.attributedString(markdown: "| a | b |\n|---|---|\n| 1 | 2 |\n")
        XCTAssertEqual(a.string, "a\tb\n1\t2")
    }

    func testCopyAlternateWritesRTFAndMarkdown() {
        let c = EditorController(textStorage: NSTextStorage(string: "hello **world**"))
        c.textView.setSelectedRange(NSRange(location: 0, length: 15))
        c.textView.copyAlternate(nil)
        let pb = NSPasteboard.general
        XCTAssertEqual(pb.string(forType: .string), "hello world")
        XCTAssertNotNil(pb.data(forType: .rtf))
        XCTAssertEqual(pb.string(forType: NSPasteboard.PasteboardType("net.daringfireball.markdown")), "hello **world**")
        // Swapped default: ⌘C copies rich, alternate copies source
        c.textView.copiesRichTextByDefault = true
        c.textView.copyAlternate(nil)
        XCTAssertEqual(pb.string(forType: .string), "hello **world**")
        c.textView.copy(nil)
        XCTAssertEqual(pb.string(forType: .string), "hello world")
    }
}

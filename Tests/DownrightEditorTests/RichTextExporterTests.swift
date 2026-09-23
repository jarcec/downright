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

    /// A table pastes as a table: every cell is a paragraph in an NSTextTable, which is
    /// what RTF and HTML carry into other apps.
    func testTablesBecomeRealTables() {
        let a = RichTextExporter.attributedString(markdown: "| a | b |\n|---|:-:|\n| 1 | 2 |\n")
        XCTAssertEqual(a.string, "a\nb\n1\n2\n", "one cell per paragraph, then the spacer that follows a table")

        var blocks: [NSTextTableBlock] = []
        a.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: a.length)) { value, _, _ in
            blocks += ((value as? NSParagraphStyle)?.textBlocks as? [NSTextTableBlock]) ?? []
        }
        XCTAssertEqual(blocks.count, 4, "one block per cell")
        XCTAssertEqual(Set(blocks.map(\.table)).count, 1, "all four in the same table")
        XCTAssertEqual(blocks[0].table.numberOfColumns, 2)
        XCTAssertEqual(blocks.map(\.startingRow), [0, 0, 1, 1])
        XCTAssertEqual(blocks.map(\.startingColumn), [0, 1, 0, 1])

        // The delimiter row's alignment reaches the cells, and the header is set apart.
        func style(_ needle: String) -> NSParagraphStyle {
            a.attribute(.paragraphStyle, at: (a.string as NSString).range(of: needle).location, effectiveRange: nil) as! NSParagraphStyle
        }
        XCTAssertEqual(style("2").alignment, .center)
        XCTAssertEqual(style("1").alignment, .natural)
        let header = a.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        XCTAssertTrue(header.fontDescriptor.symbolicTraits.contains(.bold), "header row is bold")

        // And it survives the conversions the pasteboard uses.
        let rtf = try! a.data(from: NSRange(location: 0, length: a.length),
                              documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        XCTAssertTrue(String(decoding: rtf, as: UTF8.self).contains("\\trowd"), "RTF carries a table row")
        // What another app reads back is still a table, cell for cell.
        let reread = try! NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        var rereadCells = 0
        reread.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: reread.length)) { value, _, _ in
            if ((value as? NSParagraphStyle)?.textBlocks.isEmpty == false) { rereadCells += 1 }
        }
        XCTAssertEqual(rereadCells, 4, "all four cells survive the round trip")
        let html = String(decoding: RichTextExporter.html(a)!, as: UTF8.self)
        XCTAssertTrue(html.contains("<table"), "HTML carries a table")
    }

    func testCopyPutsHTMLOnThePasteboardToo() {
        let c = EditorController(textStorage: NSTextStorage(string: "| a | b |\n|---|---|\n| 1 | 2 |\n"))
        c.textView.setSelectedRange(NSRange(location: 0, length: c.textView.string.utf16.count))
        c.textView.copyAsRichText(nil)
        let html = NSPasteboard.general.string(forType: .html) ?? ""
        XCTAssertTrue(html.contains("<table"), "a table reaches apps that prefer HTML")
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

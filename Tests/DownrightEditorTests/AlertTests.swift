import XCTest
import AppKit
import MarkdownKit
@testable import DownrightEditor

/// GitHub alerts: `> [!NOTE]` quotes read as tinted callouts with an icon and a title.
@MainActor
final class AlertTests: XCTestCase {
    static let text = """
        Intro.

        > [!NOTE]
        > Useful information that users should know, even when skimming content.

        > [!TIP]
        > Helpful advice for doing things better or more easily.

        > [!IMPORTANT]
        > Key information users need to know to achieve their goal.

        > [!WARNING]
        > Urgent info that needs immediate user attention to avoid problems.

        > [!CAUTION]
        > Advises about risks or negative outcomes of certain actions.

        > [!nonsense]
        > Just a quote.

        """

    func testDetection() {
        let ns = Self.text as NSString
        let doc = MarkdownParser.parse(Self.text)
        let kinds = doc.blocks.map { $0.alert(in: ns)?.kind }
        XCTAssertEqual(kinds, [nil, .note, .tip, .important, .warning, .caution, nil])
        let note = doc.blocks[1].alert(in: ns)!
        XCTAssertEqual(ns.substring(with: note.marker), "[!NOTE]")
        XCTAssertNil(MarkdownParser.parse("> [!NOTE] with words\n").blocks[0].alert(in: "> [!NOTE] with words\n"), "the marker stands alone")
        XCTAssertEqual(MarkdownParser.parse("> [!warning]\n> x\n").blocks[0].alert(in: "> [!warning]\n> x\n")?.kind, .warning, "any case")
    }

    func testTheMarkerLineReadsAsATitle() {
        let c = EditorController(textStorage: NSTextStorage(string: Self.text))
        let ns = Self.text as NSString
        let line = ns.range(of: "> [!WARNING]").location
        let d = c.engine.decoration(forParagraphAt: line)
        XCTAssertEqual(d.quoteAlert, .warning)
        let marker = ns.range(of: "[!WARNING]")
        XCTAssertTrue(d.substitutions.contains { $0.offset == marker.location && $0.char == 0xFFFC }, "the [ carries the icon")
        let title = d.substitutions.filter { $0.offset > marker.location }.map { Character(UnicodeScalar($0.char)!) }
        XCTAssertEqual(String(title), "arning", "WARNING reads Warning")
        XCTAssertEqual(c.engine.decoration(forParagraphAt: ns.range(of: "> Urgent").location).quoteAlert, .warning, "the body is tinted too")
        XCTAssertNil(c.engine.decoration(forParagraphAt: ns.range(of: "> Just").location).quoteAlert)
    }

    func testRichTextGetsTheTitle() {
        let rich = RichTextExporter.attributedString(markdown: "> [!TIP]\n> Use the keyboard.\n")
        XCTAssertEqual(rich.string, "Tip\nUse the keyboard.")
    }

    func testSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOTS"] else { return }
        for (name, palette) in [("alerts-paper", Palette.paper), ("alerts-ink", Palette.ink)] {
            var theme = Theme(); theme.palette = palette
            let c = EditorController(textStorage: NSTextStorage(string: Self.text), theme: theme)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = c.scrollView
            c.scrollView.frame = window.contentView!.bounds
            c.textView.setSelectedRange(NSRange(location: 0, length: 0))
            window.layoutIfNeeded()
            c.scrollView.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(c.scrollView.bitmapImageRepForCachingDisplay(in: c.scrollView.bounds))
            c.scrollView.cacheDisplay(in: c.scrollView.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}

extension AlertTests {
    func testRevealedSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOTS"] else { return }
        let c = EditorController(textStorage: NSTextStorage(string: Self.text))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = window.contentView!.bounds
        c.textView.setSelectedRange(NSRange(location: (Self.text as NSString).range(of: "[!NOTE]").location + 3, length: 0))
        window.layoutIfNeeded()
        c.scrollView.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(c.scrollView.bitmapImageRepForCachingDisplay(in: c.scrollView.bounds))
        c.scrollView.cacheDisplay(in: c.scrollView.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/alerts-revealed.png"))
    }
}

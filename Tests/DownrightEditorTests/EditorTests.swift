import XCTest
import AppKit
import MarkdownKit
@testable import DownrightEditor

@MainActor
final class EditorTests: XCTestCase {
    private func make(_ text: String) -> (EditorController, NSTextStorage) {
        let storage = NSTextStorage(string: text)
        let c = EditorController(textStorage: storage)
        c.textView.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        return (c, storage)
    }

    private func frames(_ c: EditorController) -> [(src: Int, y: CGFloat, h: CGFloat, text: String)] {
        var out: [(Int, CGFloat, CGFloat, String)] = []
        c.layoutManager.enumerateTextLayoutFragments(from: c.layoutManager.documentRange.location, options: [.ensuresLayout]) { f in
            let loc = c.contentStorage.offset(from: c.contentStorage.documentRange.location, to: f.textElement!.elementRange!.location)
            out.append((loc, f.layoutFragmentFrame.origin.y, f.layoutFragmentFrame.height, f.textLineFragments.first?.attributedString.string ?? ""))
            return true
        }
        return out
    }

    func testDisplayLengthEqualsSourceLength() {
        let (c, _) = make("# Title\nSome **bold** [link](http://x) here.\n- [ ] task\n> quote\n```swift\nlet x = 1\n```\n---\nend")
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        for f in frames(c) {
            let pr = c.lines.paragraphRange(ofLine: c.lines.line(containing: f.src))
            let lf = c.layoutManager.textLayoutFragment(for: c.contentStorage.location(c.contentStorage.documentRange.location, offsetBy: f.src)!)!
            let displayed = lf.textLineFragments.reduce(0) { $0 + $1.characterRange.length }
            XCTAssertEqual(displayed, pr.length, "paragraph at \(f.src) must be length-identical")
        }
    }

    func testFenceLinesCollapseWhenConcealed() {
        let (c, _) = make("before\n```swift\nlet x = 1\n```\nafter\n")
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))   // caret on 'before' → fence concealed
        let fs = frames(c)
        let fenceOpen = fs.first { $0.src == 7 }!
        let fenceClose = fs.first { $0.src == 26 }!
        XCTAssertEqual(fenceOpen.h, 0, "concealed opening fence must have zero height")
        XCTAssertEqual(fenceClose.h, 0, "concealed closing fence must have zero height")
        let code = fs.first { $0.src == 16 }!
        XCTAssertEqual(code.y, fenceOpen.y, "code line must sit where the hidden fence was")
        let after = fs.first { $0.src == 30 }!
        XCTAssertEqual(after.y, code.y + code.h, accuracy: 0.5, "'after' must follow the code line directly")

        // Move the caret into the block → the whole construct reveals, fences get height back
        c.textView.setSelectedRange(NSRange(location: 18, length: 0))
        let fs2 = frames(c)
        XCTAssertGreaterThan(fs2.first { $0.src == 7 }!.h, 10)
        XCTAssertGreaterThan(fs2.first { $0.src == 26 }!.h, 10)
    }

    func testRevealPolicy() {
        let src = "a\n```\ncode\n```\nb\n"
        let doc = MarkdownParser.parse(src)
        let lines = LineIndex(src)
        XCTAssertEqual(RevealPolicy.revealedRanges(selections: [NSRange(location: 0, length: 0)], document: doc, lines: lines), [NSRange(location: 0, length: 2)])
        XCTAssertEqual(RevealPolicy.revealedRanges(selections: [NSRange(location: 7, length: 0)], document: doc, lines: lines), [NSRange(location: 2, length: 13)], "inside a fence reveals the whole fence")
        XCTAssertEqual(RevealPolicy.revealedRanges(selections: [NSRange(location: 0, length: 16)], document: doc, lines: lines), [NSRange(location: 0, length: 17)])
    }

    func testCaretMoveInvalidatesTwoParagraphs() {
        var text = ""
        for i in 0..<2000 { text += "# H\(i)\nSome **bold** text \(i).\n\n" }
        let (c, _) = make(text)
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        _ = frames(c)
        c.textView.setSelectedRange(NSRange(location: 6, length: 0))  // next line
        XCTAssertLessThanOrEqual(c.lastRevealInvalidationCount, 2)
    }

    func testDirtyRangeResyncs() {
        let old = MarkdownParser.parse("# A\n\npara\n\n# B\n\nmore\n")
        let new = MarkdownParser.parse("# A\n\nparaX\n\n# B\n\nmore\n")
        let r = EditorController.dirtyRange(old: old, new: new, edit: NSRange(location: 9, length: 1), delta: 1)
        XCTAssertEqual(r, NSRange(location: 0, length: 12), "from the previous block to the resync point (`# B`)")
    }

    func testTypingKeepsBackingPristineAndCopiesSource() {
        let (c, storage) = make("# T\nSome **bold**.")
        c.textView.setSelectedRange(NSRange(location: storage.length, length: 0))
        c.textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(storage.string, "# T\nSome **bold**.!")
        XCTAssertEqual(c.textView.string, "# T\nSome **bold**.!")
        XCTAssertEqual(c.document.blocks.count, 2)
    }

    func testLineNumberGutterKeepsTextKit2AndRendersText() {
        let (c, _) = make("# T\nline\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let gutter = LineNumberGutterView(controller: c)
        c.scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(gutter); container.addSubview(c.scrollView)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor), gutter.topAnchor.constraint(equalTo: container.topAnchor), gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            c.scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor), c.scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            c.scrollView.topAnchor.constraint(equalTo: container.topAnchor), c.scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        XCTAssertNotNil(c.textView.textLayoutManager)
        XCTAssertTrue(c.textView.textLayoutManager === c.layoutManager)
        XCTAssertGreaterThan(gutter.thickness, 20)
        XCTAssertEqual(c.scrollView.contentView.bounds.origin.x, 0, "clip view must not be shifted by the gutter")
        // Render and make sure the text actually produced dark pixels
        guard let rep = c.scrollView.bitmapImageRepForCachingDisplay(in: c.scrollView.bounds) else { return XCTFail("no bitmap") }
        c.scrollView.cacheDisplay(in: c.scrollView.bounds, to: rep)
        var dark = 0
        for y in stride(from: 0, to: Int(rep.pixelsHigh), by: 4) {
            for x in stride(from: 0, to: Int(rep.pixelsWide), by: 4) {
                if let col = rep.colorAt(x: x, y: y), col.brightnessComponent < 0.5 { dark += 1 }
            }
        }
        XCTAssertGreaterThan(dark, 10, "text should be visible next to the gutter")
    }
}

@MainActor
final class LinkPasteTests: XCTestCase {
    private func make(_ text: String) -> EditorController {
        let c = EditorController(textStorage: NSTextStorage(string: text))
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        return c
    }

    func testPastingURLOverSelectionMakesLink() {
        let c = make("see the docs here")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://example.com/docs", forType: .string)
        c.textView.setSelectedRange(NSRange(location: 8, length: 4))   // "docs"
        c.textView.paste(nil)
        XCTAssertEqual(c.textView.string, "see the [docs](https://example.com/docs) here")
    }

    func testPastingPlainTextOverSelectionReplaces() {
        let c = make("see the docs here")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("manual", forType: .string)
        c.textView.setSelectedRange(NSRange(location: 8, length: 4))
        c.textView.paste(nil)
        XCTAssertEqual(c.textView.string, "see the manual here")
    }

    func testPastingURLWithoutSelectionIsLiteral() {
        let c = make("x")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://example.com", forType: .string)
        c.textView.setSelectedRange(NSRange(location: 1, length: 0))
        c.textView.paste(nil)
        XCTAssertEqual(c.textView.string, "xhttps://example.com")
    }

    func testURLDetection() {
        let pb = NSPasteboard(name: NSPasteboard.Name("test.\(UUID())"))
        for (s, ok) in [("https://a.b/c?d=1", true), ("http://x", true), ("mailto:me@x.org", true),
                        ("not a url", false), ("https://a b", false), ("file:///etc", false), ("example.com", false)] {
            pb.clearContents(); pb.setString(s, forType: .string)
            XCTAssertEqual(MarkdownTextView.pastedURL(from: pb) != nil, ok, s)
        }
    }

    func testContextMenuOffersInsertLinkForSelection() {
        let c = make("hello world\n\n\n\n\n\n")   // blank lines give the click empty space
        c.textView.setSelectedRange(NSRange(location: 0, length: 5))
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let titles = c.textView.menu(for: event)?.items.map(\.title) ?? []
        XCTAssertEqual(Array(titles.prefix(4)), ["Insert Link", "Bold", "Italic", "Inline Code"])
        // Right-clicking on a word auto-selects it (standard NSTextView behaviour), so the
        // no-selection case must click empty space below the text.
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let empty = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 300, y: 110), modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let plain = c.textView.menu(for: empty)?.items.map(\.title) ?? []
        XCTAssertFalse(plain.contains("Insert Link"), "menu without selection: \(plain)")
    }
}

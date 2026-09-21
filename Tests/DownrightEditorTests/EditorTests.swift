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
        // A real window so the event's location converts to view coordinates.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.layoutIfNeeded()
        func rightClick(atTextViewPoint p: NSPoint) -> [String] {
            let inWindow = c.textView.convert(p, to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: inWindow, modifierFlags: [], timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return c.textView.menu(for: event)?.items.map(\.title) ?? []
        }
        c.textView.setSelectedRange(NSRange(location: 0, length: 5))
        let inside = c.caretRect(at: 2).map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSPoint(x: 40, y: 34)
        let titles = rightClick(atTextViewPoint: inside)
        XCTAssertEqual(Array(titles.prefix(4)), ["Insert Link", "Bold", "Italic", "Inline Code"], "selection after menu: \(c.textView.selectedRange())")
        // Right-click on a blank line auto-selects at most the newline: no formatting offered.
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let blank = c.caretRect(at: 14).map { NSPoint(x: 300, y: $0.midY) } ?? NSPoint(x: 300, y: 110)
        let plain = rightClick(atTextViewPoint: blank)
        XCTAssertFalse(plain.contains("Insert Link"), "selection \(c.textView.selectedRange()) menu: \(plain.prefix(6))")
    }
}

@MainActor
final class CompactBlankLineTests: XCTestCase {
    func testBlankLinesAroundHeadingsAreCompactUnlessCaretIsThere() {
        let s = NSTextStorage(string: "para\n\n# Title\n\nbody\n\nmore\n")
        //                              0 para,1 blank(before H),2 #,3 blank(after H),4 body,5 blank(plain),6 more
        let c = EditorController(textStorage: s)
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        func heights() -> [Int: CGFloat] {
            var h: [Int: CGFloat] = [:]
            c.layoutManager.enumerateTextLayoutFragments(from: c.layoutManager.documentRange.location, options: [.ensuresLayout]) { f in
                let loc = c.contentStorage.offset(from: c.contentStorage.documentRange.location, to: f.textElement!.elementRange!.location)
                h[c.lines.line(containing: loc)] = f.layoutFragmentFrame.height; return true
            }
            return h
        }
        var h = heights()
        XCTAssertLessThan(h[1]!, h[5]! * 0.6, "blank before heading is compact: \(h)")
        XCTAssertLessThan(h[3]!, h[5]! * 0.6, "blank after heading is compact")
        XCTAssertGreaterThan(h[5]!, 15, "ordinary blank line keeps full height")
        // Caret on the compact line restores full height for editing
        c.textView.setSelectedRange(NSRange(location: 5, length: 0))
        h = heights()
        XCTAssertEqual(h[1]!, h[5]!, accuracy: 0.5)
    }

    func testBlankLinesAroundTablesAreCompact() {
        let s = NSTextStorage(string: "para\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nbody\n\nmore\n")
        //                              0 para,1 blank(before T),2-4 table,5 blank(after T),6 body,7 blank(plain),8 more
        let c = EditorController(textStorage: s)
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        var h: [Int: CGFloat] = [:]
        c.layoutManager.enumerateTextLayoutFragments(from: c.layoutManager.documentRange.location, options: [.ensuresLayout]) { f in
            let loc = c.contentStorage.offset(from: c.contentStorage.documentRange.location, to: f.textElement!.elementRange!.location)
            h[c.lines.line(containing: loc)] = f.layoutFragmentFrame.height; return true
        }
        XCTAssertLessThan(h[1]!, h[7]! * 0.6, "blank before table is compact: \(h)")
        XCTAssertLessThan(h[5]!, h[7]! * 0.6, "blank after table is compact")
        XCTAssertGreaterThan(h[7]!, 15, "ordinary blank line keeps full height")
    }

    func testBlankLinesAroundQuotesAreCompact() {
        let s = NSTextStorage(string: "para\n\n> quoted\n> more\n\nbody\n\nmore\n")
        //                              0 para,1 blank(before Q),2-3 quote,4 blank(after Q),5 body,6 blank(plain),7 more
        let c = EditorController(textStorage: s)
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        var h: [Int: CGFloat] = [:]
        c.layoutManager.enumerateTextLayoutFragments(from: c.layoutManager.documentRange.location, options: [.ensuresLayout]) { f in
            let loc = c.contentStorage.offset(from: c.contentStorage.documentRange.location, to: f.textElement!.elementRange!.location)
            h[c.lines.line(containing: loc)] = f.layoutFragmentFrame.height; return true
        }
        XCTAssertLessThan(h[1]!, h[6]! * 0.6, "blank before quote is compact: \(h)")
        XCTAssertLessThan(h[4]!, h[6]! * 0.6, "blank after quote is compact")
        XCTAssertGreaterThan(h[6]!, 15, "ordinary blank line keeps full height")
    }
}

@MainActor
final class ListGuideTests: XCTestCase {
    func testNestedListItemsGetIndentGuidesUnderTheirParentsBullet() {
        let c = EditorController(textStorage: NSTextStorage(string: "* 1\n  * A\n    * x\n    * y\n  * B\n\nend\n"))
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        // lines: 0 1, 1 A, 2 x, 3 y, 4 B, 5 blank, 6 end
        c.textView.setSelectedRange(NSRange(location: c.lines.lineStarts[6], length: 0))
        func guides(_ line: Int) -> [CGFloat] { c.engine.decoration(forParagraphAt: c.lines.lineStarts[line]).listGuides }
        XCTAssertEqual(guides(0).count, 0)
        XCTAssertEqual(guides(1).count, 1)
        XCTAssertEqual(guides(2).count, 2)
        XCTAssertEqual(guides(3).count, 2)
        XCTAssertEqual(guides(4).count, 1)
        XCTAssertEqual(guides(6).count, 0)

        // Each guide sits at the centre of the rendered bullet it hangs from.
        func bulletCentre(line: Int, column: Int) -> CGFloat {
            let doc = c.contentStorage.documentRange.location
            let lf = c.layoutManager.textLayoutFragment(for: c.contentStorage.location(doc, offsetBy: c.lines.lineStarts[line])!)!
            let tl = lf.textLineFragments[0]
            return lf.layoutFragmentFrame.minX + (tl.locationForCharacter(at: column).x + tl.locationForCharacter(at: column + 1).x) / 2
        }
        c.layoutManager.ensureLayout(for: c.layoutManager.documentRange)
        XCTAssertEqual(guides(2)[0], bulletCentre(line: 0, column: 0), accuracy: 0.5)
        XCTAssertEqual(guides(2)[1], bulletCentre(line: 1, column: 2), accuracy: 0.5)
        XCTAssertEqual(guides(4)[0], guides(2)[0])
    }

    private func editor(_ text: String) -> EditorController {
        let c = EditorController(textStorage: NSTextStorage(string: text))
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        return c
    }
    /// Display x of the marker on `line`: the paragraph's indent plus the source's own
    /// leading spaces, which are real characters and keep their width.
    private func markerX(_ c: EditorController, line: Int) -> CGFloat {
        let cr = c.lines.contentRange(ofLine: line)
        let source = (c.textStorage.string as NSString).substring(with: cr)
        let spaces = source.prefix(while: { $0 == " " }).count
        return c.engine.decoration(forParagraphAt: cr.location).firstLineHeadIndent
            + CGFloat(spaces) * c.theme.spaceWidth
    }

    /// Two spaces per level barely reads, so every level steps by a full
    /// `listIndentColumns` on screen — and a source that already indents that far or more
    /// is left where it is.
    func testNestingStepsByAFullIndentWhateverTheSourceUses() {
        for source in ["* 1\n  * A\n    * x\n", "* 1\n   * A\n      * x\n", "* 1\n    * A\n        * x\n"] {
            let c = editor(source)
            let step = c.theme.listIndentColumns * c.theme.spaceWidth
            XCTAssertEqual(markerX(c, line: 0), 0, accuracy: 0.01, source.debugDescription)
            XCTAssertEqual(markerX(c, line: 1), step, accuracy: 0.01, source.debugDescription)
            XCTAssertEqual(markerX(c, line: 2), 2 * step, accuracy: 0.01, source.debugDescription)
        }
    }

    /// A quote's `>` markers are concealed and stand in as the quote's indent, so they
    /// must not count towards the nesting.
    func testQuotedListNestsWithoutCountingItsQuoteMarkers() {
        let c = editor("> * one\n>   * two\n")
        let step = c.theme.listIndentColumns * c.theme.spaceWidth
        func indent(_ line: Int) -> CGFloat {
            c.engine.decoration(forParagraphAt: c.lines.lineStarts[line]).firstLineHeadIndent
        }
        XCTAssertEqual(indent(0), c.theme.quoteIndent, accuracy: 0.01)
        XCTAssertEqual(indent(1) + 2 * c.theme.spaceWidth, c.theme.quoteIndent + step, accuracy: 0.01)
    }

    /// A wrapped line hangs at its item's content column, which moves with the indent.
    func testNestedItemHangsAtItsContentColumn() {
        let c = editor("* 1\n  * A\n")
        let d = c.engine.decoration(forParagraphAt: c.lines.lineStarts[1])
        // The source's own "  " and the "* " the bullet replaces, past the display indent.
        XCTAssertEqual(d.headIndent, d.firstLineHeadIndent + 4 * c.theme.spaceWidth, accuracy: 0.01)
    }
}

@MainActor
final class ListMarkerTintTests: XCTestCase {
    private func make(_ text: String) -> EditorController {
        let c = EditorController(textStorage: NSTextStorage(string: text))
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        return c
    }
    private func paragraph(_ c: EditorController, line: Int) -> NSAttributedString {
        let pr = c.lines.paragraphRange(ofLine: line)
        return c.contentStorage.delegate!.textContentStorage!(c.contentStorage, textParagraphWith: pr)!.attributedString
    }
    private func colour(_ a: NSAttributedString, _ i: Int) -> String? {
        (a.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor)?.hexString
    }

    /// The raw `-`/`*`/`+` is syntax the rendered line replaces with ●, so on the caret's
    /// line it tints like any other revealed marker instead of staying grey.
    func testRevealedBulletMarkerIsTinted() {
        for bullet in ["-", "*", "+"] {
            let c = make("\(bullet) item\n\(bullet) other\n")
            c.textView.setSelectedRange(NSRange(location: 2, length: 0))
            XCTAssertEqual(colour(paragraph(c, line: 0), 0), c.theme.markerColor.hexString, "\(bullet) revealed")
            XCTAssertEqual(colour(paragraph(c, line: 1), 0), c.theme.listMarkerColor.hexString, "\(bullet) concealed (●)")
        }
    }

    func testRevealedTaskBulletIsTintedButTheCheckboxIsNot() {
        let c = make("- [ ] task\n- [x] done\n")
        c.textView.setSelectedRange(NSRange(location: 2, length: 0))
        let line = paragraph(c, line: 0)
        XCTAssertEqual(colour(line, 0), c.theme.markerColor.hexString, "the '-' tints")
        XCTAssertEqual(colour(line, 2), c.theme.secondaryColor.hexString, "the checkbox keeps its own colour")
    }

    /// An ordered item's `1.` is syntax too, so it tints on the caret's line and keeps the
    /// list marker colour everywhere else.
    func testRevealedOrderedMarkerIsTinted() {
        let c = make("1. one\n2. two\n")
        c.textView.setSelectedRange(NSRange(location: 3, length: 0))
        let revealed = paragraph(c, line: 0)
        XCTAssertEqual(colour(revealed, 0), c.theme.markerColor.hexString, "the '1' tints")
        XCTAssertEqual(colour(revealed, 1), c.theme.markerColor.hexString, "and so does the '.'")
        XCTAssertEqual(colour(revealed, 3), c.theme.textColor.hexString, "the item's text does not")
        XCTAssertEqual(colour(paragraph(c, line: 1), 0), c.theme.listMarkerColor.hexString)
    }
}

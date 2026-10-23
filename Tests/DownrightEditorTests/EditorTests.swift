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
final class CopyFormatTests: XCTestCase {
    private func make(_ text: String, mode: EditorController.Mode = .live) -> EditorController {
        let c = EditorController(textStorage: NSTextStorage(string: text))
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        c.mode = mode
        c.textView.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        return c
    }
    /// Rich text reaches the pasteboard as RTF; the Markdown source does not.
    private func pasteboardIsRich() -> Bool {
        NSPasteboard.general.data(forType: .rtf) != nil
    }

    /// In View mode the source is not on screen, and the reason to select is to paste
    /// somewhere else — so ⌘C hands over formatted text whatever the setting says.
    func testViewModeCopiesRichText() {
        let c = make("# Title\n", mode: .view)
        XCTAssertTrue(c.textView.copiesRichText)
        NSPasteboard.general.clearContents()
        c.textView.copy(nil)
        XCTAssertTrue(pasteboardIsRich())
        XCTAssertEqual(NSPasteboard.general.string(forType: NSPasteboard.PasteboardType("net.daringfireball.markdown")), "# Title\n")
    }

    func testLiveModeStillCopiesSourceByDefault() {
        let c = make("# Title\n")
        XCTAssertFalse(c.textView.copiesRichText)
        NSPasteboard.general.clearContents()
        c.textView.copy(nil)
        XCTAssertFalse(pasteboardIsRich())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "# Title\n")
    }

    /// ⌘⇧C is always the other one, so View mode can still yield Markdown.
    func testAlternateCopyInViewModeGivesMarkdown() {
        let c = make("# Title\n", mode: .view)
        NSPasteboard.general.clearContents()
        c.textView.copyAlternate(nil)
        XCTAssertFalse(pasteboardIsRich())
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "# Title\n")
    }

    /// Both formats are named in the context menu, and stay available where the document
    /// cannot be edited.
    func testContextMenuNamesBothCopyFormats() {
        let c = make("# Title\n", mode: .view)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let titles = c.textView.menu(for: event)?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains("Copy as Rich Text"), "\(titles)")
        XCTAssertTrue(titles.contains("Copy as Markdown"), "\(titles)")
        for selector in [#selector(MarkdownTextView.copyAsRichText(_:)), #selector(MarkdownTextView.copyAsMarkdown(_:))] {
            let item = NSMenuItem(title: "", action: selector, keyEquivalent: "")
            XCTAssertTrue(c.textView.validateUserInterfaceItem(item), "\(selector) with a selection")
        }
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

    /// Right edges (container coordinates) of the laid-out lines, with their top.
    private func lineExtents(_ c: EditorController) -> [(top: CGFloat, right: CGFloat)] {
        var out: [(CGFloat, CGFloat)] = []
        c.layoutManager.ensureLayout(for: c.contentStorage.documentRange)
        c.layoutManager.enumerateTextLayoutFragments(from: c.contentStorage.documentRange.location, options: [.ensuresLayout]) { f in
            for line in f.textLineFragments where line.characterRange.length > 0 {
                let b = line.typographicBounds
                out.append((f.layoutFragmentFrame.minY + b.minY, f.layoutFragmentFrame.minX + b.maxX))
            }
            return true
        }
        return out
    }

    private func floatEditor(width: CGFloat) -> (EditorController, NSWindow) {
        let prose = String(repeating: "Words that wrap across the column and run on for a while. ", count: 40)
        let c = make("# Title\n\(prose)\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        window.layoutIfNeeded()
        return (c, window)
    }

    func testTextWrapsAroundAPageFloat() throws {
        let (c, window) = floatEditor(width: 800)
        let column = c.textContainer.size.width
        XCTAssertEqual(column, c.scrollView.contentSize.width - 56, accuracy: 0.5)
        XCTAssertNil(c.pageFloatRect)
        XCTAssertGreaterThan(lineExtents(c).first { $0.top > 40 }?.right ?? 0, column - 260, "full width without a float")

        var fired = 0
        c.onPageFloatChange = { fired += 1 }
        c.pageFloatSize = CGSize(width: 230, height: 120)
        XCTAssertEqual(fired, 1)
        let slot = try XCTUnwrap(c.pageFloatRect)
        XCTAssertEqual(slot, NSRect(x: 28 + column - 230, y: 24, width: 230, height: 120), "top-right of the column, in view coordinates")
        XCTAssertEqual(c.textContainer.size.width, column, accuracy: 0.5, "the column itself keeps its width")

        let lines = lineExtents(c)
        let beside = lines.filter { $0.top < 120 + 8 }, below = lines.filter { $0.top >= 120 + 8 }
        XCTAssertFalse(beside.isEmpty); XCTAssertFalse(below.isEmpty)
        for l in beside { XCTAssertLessThanOrEqual(l.right, column - 230 - 16 + 0.5, "a line level with the float ends before it") }
        XCTAssertGreaterThan(below.map(\.right).max() ?? 0, column - 230, "lines below the float run the full width")

        // Too narrow to leave a usable column beside it: no float, full-width lines.
        c.scrollView.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        window.layoutIfNeeded()
        XCTAssertNil(c.pageFloatRect)
        XCTAssertGreaterThan(lineExtents(c).filter { $0.top < 120 }.map(\.right).max() ?? 0, c.scrollView.contentSize.width - 56 - 230)

        c.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.layoutIfNeeded()
        XCTAssertNotNil(c.pageFloatRect, "a wider window brings it back")
        c.pageFloatSize = .zero
        XCTAssertNil(c.pageFloatRect)
        XCTAssertGreaterThan(lineExtents(c).filter { $0.top < 120 }.map(\.right).max() ?? 0, column - 230, "removing it restores the width")
    }

    func testPageFloatFollowsACentredColumn() throws {
        let (c, window) = floatEditor(width: 1200)
        c.maxContentWidth = 600
        c.pageFloatSize = CGSize(width: 230, height: 120)
        func centredRight() -> CGFloat { c.textView.textContainerInset.width + c.textContainer.size.width }
        XCTAssertGreaterThan(c.textView.textContainerInset.width, 200, "centred, not pushed aside")
        XCTAssertEqual(try XCTUnwrap(c.pageFloatRect).maxX, centredRight(), accuracy: 0.5, "flush with the column's right edge")
        c.scrollView.frame = NSRect(x: 0, y: 0, width: 1000, height: 400)
        window.layoutIfNeeded()
        XCTAssertEqual(try XCTUnwrap(c.pageFloatRect).maxX, centredRight(), accuracy: 0.5)
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
        XCTAssertEqual(Array(titles.prefix(7)),
                       ["Copy as Rich Text", "Copy as Markdown", "", "Insert Link", "Bold", "Italic", "Inline Code"],
                       "selection after menu: \(c.textView.selectedRange())")
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

@MainActor
final class TableScrollTests: XCTestCase {
    static let wide = """
    Intro.

    | Item | Fact | Source |
    |---|---|---|
    | Legal name | Estuary Technologies, Inc.; the product was renamed from Estuary Flow to Estuary in March 2026 | [18] |
    | Founded | 2019 | [2] |

    Outro.

    """

    private func make(_ text: String = wide, windowWidth: CGFloat = 420) -> (EditorController, NSString, Int) {
        let c = EditorController(textStorage: NSTextStorage(string: text))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: 500)
        window.layoutIfNeeded()
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        let start = (text as NSString).range(of: "| Item").location
        return (c, text as NSString, start)
    }

    private func lineCount(_ c: EditorController, line: Int) -> Int {
        var n = 0
        c.layoutManager.enumerateTextLayoutFragments(from: c.layoutManager.documentRange.location, options: [.ensuresLayout]) { f in
            let loc = c.contentStorage.offset(from: c.contentStorage.documentRange.location, to: f.textElement!.elementRange!.location)
            if c.lines.line(containing: loc) == line { n = f.textLineFragments.filter { $0.characterRange.length > 0 }.count; return false }
            return true
        }
        return n
    }

    func testAWideTableScrollsSidewaysUnderTheColumn() {
        let (c, s, start) = make()
        let limit = c.engine.tableScrollLimit(blockStart: start)
        XCTAssertGreaterThan(limit, 100, "the table runs well past a 420pt window")
        let year = s.range(of: "2019").location
        let before = c.caretRect(at: year)!
        XCTAssertTrue(c.scrollTable(blockStart: start, to: 100))
        let after = c.caretRect(at: year)!
        XCTAssertEqual(after.minX, before.minX - 100, accuracy: 1, "the row is laid out shifted left")
        XCTAssertEqual(after.minY, before.minY, accuracy: 0.5)
        XCTAssertEqual(lineCount(c, line: 4), 1, "the long row stays one line")
        XCTAssertEqual(c.caretRect(at: 0)!.minX, before.minX - before.minX + c.textView.textContainerInset.width, accuracy: 1, "the rest of the document does not move")
        // Clamps to the overflow; a wider column slides it back.
        c.scrollTable(blockStart: start, to: 10_000)
        XCTAssertEqual(c.tableScroll(blockStart: start), limit, accuracy: 0.5)
        c.engine.setColumnWidth(c.engine.columnWidth + 50)
        XCTAssertEqual(c.tableScroll(blockStart: start), limit - 50, accuracy: 0.5)
    }

    func testATableThatFitsDoesNotScroll() {
        let (c, _, start) = make("| a | b |\n|---|---|\n| 1 | 2 |\n", windowWidth: 600)
        XCTAssertEqual(c.engine.tableScrollLimit(blockStart: start - 0), 0)
        XCTAssertFalse(c.scrollTable(blockStart: 0, to: 50))
    }

    func testTheCaretKeepsItsCellInsideTheColumn() {
        let (c, s, start) = make()
        let source = s.range(of: "[18]").location
        c.textView.setSelectedRange(NSRange(location: source, length: 0))
        let scroll = c.tableScroll(blockStart: start)
        XCTAssertGreaterThan(scroll, 0, "the last column was off-screen; the table scrolled to it")
        let rect = c.caretRect(at: source)!
        let inset = c.textView.textContainerInset.width
        XCTAssertGreaterThanOrEqual(rect.minX, inset - 1)
        XCTAssertLessThanOrEqual(rect.maxX, inset + c.engine.columnWidth + 1)
        c.textView.setSelectedRange(NSRange(location: s.range(of: "Legal").location, length: 0))
        XCTAssertEqual(c.tableScroll(blockStart: start), 0, accuracy: 0.5, "back to the first column")
    }

    func testACellWiderThanTheColumnOnlyKeepsTheCaretInView() {
        let (c, s, start) = make()
        // The Fact cell is wider than the column: scroll a little into it and click there.
        c.scrollTable(blockStart: start, to: 120)
        let fact = s.range(of: "Estuary Technologies").location
        c.textView.setSelectedRange(NSRange(location: fact + 32, length: 0))   // clear of the pinned first column
        XCTAssertEqual(c.tableScroll(blockStart: start), 120, accuracy: 0.5, "a visible caret in a wide cell does not move the table")
        // The caret at the far end of the cell drags the table along.
        let end = s.range(of: "March 2026").end
        c.textView.setSelectedRange(NSRange(location: end, length: 0))
        let scrolled = c.tableScroll(blockStart: start)
        XCTAssertGreaterThan(scrolled, 200)
        let rect = c.caretRect(at: end)!
        let inset = c.textView.textContainerInset.width
        XCTAssertLessThanOrEqual(rect.maxX, inset + c.engine.columnWidth + 1)
        XCTAssertGreaterThan(rect.minX, inset)
        // And back to the cell's start, step by step, never losing the caret.
        c.textView.setSelectedRange(NSRange(location: fact, length: 0))
        XCTAssertLessThan(c.tableScroll(blockStart: start), scrolled)
        XCTAssertGreaterThan(c.caretRect(at: fact)!.minX, inset)
    }

    func testASidewaysGestureOverTheTableScrollsItNotThePage() {
        let (c, s, start) = make()
        let inTable = c.caretRect(at: s.range(of: "Legal").location)!
        let p = NSPoint(x: inTable.midX, y: inTable.midY)
        // Mostly vertical: not ours.
        XCTAssertFalse(c.handleTableScroll(deltaX: -3, deltaY: -20, at: p, phase: .began, momentumPhase: []))
        // Mostly horizontal, latched through the gesture and its momentum.
        XCTAssertTrue(c.handleTableScroll(deltaX: -30, deltaY: -2, at: p, phase: .began, momentumPhase: []))
        XCTAssertTrue(c.handleTableScroll(deltaX: -30, deltaY: 0, at: p, phase: .changed, momentumPhase: []))
        XCTAssertTrue(c.handleTableScroll(deltaX: 0, deltaY: 0, at: p, phase: .ended, momentumPhase: []))
        XCTAssertTrue(c.handleTableScroll(deltaX: -10, deltaY: 0, at: p, phase: [], momentumPhase: .changed))
        XCTAssertTrue(c.handleTableScroll(deltaX: 0, deltaY: 0, at: p, phase: [], momentumPhase: .ended))
        XCTAssertEqual(c.tableScroll(blockStart: start), 70, accuracy: 0.5)
        // Over ordinary text: the page's.
        let outside = c.caretRect(at: 0)!
        XCTAssertFalse(c.handleTableScroll(deltaX: -30, deltaY: 0, at: NSPoint(x: outside.midX, y: outside.midY), phase: .began, momentumPhase: []))
        XCTAssertFalse(c.handleTableScroll(deltaX: -30, deltaY: 0, at: NSPoint(x: outside.midX, y: outside.midY), phase: .changed, momentumPhase: []))
        XCTAssertEqual(c.tableScroll(blockStart: start), 70, accuracy: 0.5)
    }

    /// A trackpad gesture opens with events that carry no movement; the decision waits for
    /// the first one that does, instead of handing the whole gesture to the page.
    func testAGestureThatOpensStillIsDecidedOnItsFirstMovement() {
        let (c, s, start) = make()
        let inTable = c.caretRect(at: s.range(of: "Legal").location)!
        let p = NSPoint(x: inTable.midX, y: inTable.midY)
        XCTAssertFalse(c.handleTableScroll(deltaX: 0, deltaY: 0, at: p, phase: .mayBegin, momentumPhase: []))
        XCTAssertFalse(c.handleTableScroll(deltaX: 0, deltaY: 0, at: p, phase: .began, momentumPhase: []))
        XCTAssertTrue(c.handleTableScroll(deltaX: -25, deltaY: -1, at: p, phase: .changed, momentumPhase: []))
        XCTAssertTrue(c.handleTableScroll(deltaX: -15, deltaY: 0, at: p, phase: .changed, momentumPhase: []))
        XCTAssertEqual(c.tableScroll(blockStart: start), 40, accuracy: 0.5)
        // A vertical one that opens still stays the page's throughout.
        XCTAssertFalse(c.handleTableScroll(deltaX: 0, deltaY: 0, at: p, phase: .began, momentumPhase: []))
        XCTAssertFalse(c.handleTableScroll(deltaX: -1, deltaY: -20, at: p, phase: .changed, momentumPhase: []))
        XCTAssertFalse(c.handleTableScroll(deltaX: -30, deltaY: 0, at: p, phase: .changed, momentumPhase: []))
        XCTAssertEqual(c.tableScroll(blockStart: start), 40, accuracy: 0.5)
    }

    /// A wide table shows a scroll bar under it, in room kept for it, across the column;
    /// dragging the knob scrolls that table and nothing else.
    func testAWideTableHasAScrollBarThatScrollsIt() {
        let (c, s, start) = make()
        let bars = c.textView.visibleTableScrollBars
        XCTAssertEqual(bars.count, 1)
        guard let bar = bars.first else { return }
        let inset = c.textView.textContainerInset.width
        XCTAssertEqual(bar.frame.minX, inset, accuracy: 0.5)
        XCTAssertEqual(bar.frame.width, c.engine.columnWidth, accuracy: 0.5)
        let lastRow = c.caretRect(at: s.range(of: "Founded").location)!
        let outro = c.caretRect(at: s.range(of: "Outro").location)!
        XCTAssertGreaterThanOrEqual(bar.frame.minY, lastRow.maxY, "below the last row")
        XCTAssertLessThan(bar.frame.maxY, outro.minY, "and clear of the text after the table")
        XCTAssertLessThan(bar.knobRect.width, bar.frame.width, "the knob shows how much is in view")

        // Drag the knob all the way right: the table reaches its end; the page stays put.
        let window = c.textView.window!
        func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
            let p = bar.convert(NSPoint(x: x, y: bar.bounds.midY), to: nil)
            return NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let knob = bar.knobRect
        bar.mouseDown(with: event(.leftMouseDown, x: knob.midX))
        bar.mouseDragged(with: event(.leftMouseDragged, x: knob.midX + bar.bounds.width))
        bar.mouseUp(with: event(.leftMouseUp, x: knob.midX + bar.bounds.width))
        XCTAssertEqual(c.tableScroll(blockStart: start), c.engine.tableScrollLimit(blockStart: start), accuracy: 0.5)
        XCTAssertEqual(bar.knobRect.maxX, bar.bounds.width, accuracy: 0.5)
        XCTAssertEqual(c.caretRect(at: 0)!.minX, inset, accuracy: 1, "the rest of the document does not move")
        // A click on the track's left end jumps back.
        bar.mouseDown(with: event(.leftMouseDown, x: 1))
        bar.mouseUp(with: event(.leftMouseUp, x: 1))
        XCTAssertEqual(c.tableScroll(blockStart: start), 0, accuracy: 0.5)
    }

    /// A table that fits has no bar and keeps no room for one; widening the window until
    /// the wide table fits takes its bar away.
    func testATableThatFitsHasNoScrollBar() {
        let (c, _, _) = make("| a | b |\n|---|---|\n| 1 | 2 |\n\nAfter.\n", windowWidth: 600)
        XCTAssertTrue(c.textView.visibleTableScrollBars.isEmpty)
        let (wide, _, _) = make()
        XCTAssertEqual(wide.textView.visibleTableScrollBars.count, 1)
        wide.textView.window!.setContentSize(NSSize(width: 2400, height: 500))
        wide.scrollView.frame = NSRect(x: 0, y: 0, width: 2400, height: 500)
        wide.textView.window!.layoutIfNeeded()
        wide.textView.updateTableScrollBars()
        XCTAssertTrue(wide.textView.visibleTableScrollBars.isEmpty)
    }
}

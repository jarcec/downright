import XCTest
import AppKit
import MarkdownKit
@testable import DownrightEditor

@MainActor
final class ImageTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("downright-images-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// A solid PNG of the given pixel size at 72 dpi, so its point size equals its pixel size.
    @discardableResult
    private func writePNG(_ name: String, width: Int, height: Int, color: NSColor = .red) -> URL {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let url = dir.appendingPathComponent(name)
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private func make(_ text: String, width: CGFloat = 600) -> EditorController {
        let c = EditorController(textStorage: NSTextStorage(string: text))
        c.textView.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        c.baseURL = dir.appendingPathComponent("doc.md")
        return c
    }

    private func paragraph(_ c: EditorController, line: Int) -> NSAttributedString {
        let pr = c.lines.paragraphRange(ofLine: line)
        return c.contentStorage.delegate!.textContentStorage!(c.contentStorage, textParagraphWith: pr)!.attributedString
    }

    /// Run the main loop until the loader has the image (loads are asynchronous).
    private func waitForImage(_ c: EditorController, _ url: URL, timeout: TimeInterval = 5) -> NSImage? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .loaded(let img) = c.images.image(for: url) { return img }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return nil
    }

    private func fragmentHeight(_ c: EditorController, line: Int) -> CGFloat {
        let pr = c.lines.paragraphRange(ofLine: line)
        let loc = c.contentStorage.location(c.contentStorage.documentRange.location, offsetBy: pr.location)!
        c.layoutManager.ensureLayout(for: NSTextRange(location: loc))
        return c.layoutManager.textLayoutFragment(for: loc)!.layoutFragmentFrame.height
    }

    // MARK: - Resolution

    func testDestinationResolution() {
        let base = URL(fileURLWithPath: "/tmp/notes/doc.md")
        XCTAssertEqual(ImageLoader.resolve("img/a.png", baseURL: base)?.path, "/tmp/notes/img/a.png")
        XCTAssertEqual(ImageLoader.resolve("../a.png", baseURL: base)?.path, "/tmp/a.png")
        XCTAssertEqual(ImageLoader.resolve("my%20image.png", baseURL: base)?.path, "/tmp/notes/my image.png")
        XCTAssertEqual(ImageLoader.resolve("/abs/a.png", baseURL: nil)?.path, "/abs/a.png")
        XCTAssertEqual(ImageLoader.resolve("file:///abs/b.png", baseURL: nil)?.path, "/abs/b.png")
        XCTAssertEqual(ImageLoader.resolve("https://example.com/a.png", baseURL: base)?.scheme, "https")
        XCTAssertNil(ImageLoader.resolve("img/a.png", baseURL: nil), "a relative path needs a document location")
        XCTAssertNil(ImageLoader.resolve("", baseURL: base))
        XCTAssertEqual(ImageLoader.resolve("~/a.png", baseURL: nil)?.path, (("~/a.png" as NSString).expandingTildeInPath))
    }

    // MARK: - Rendering

    func testConcealedImageParagraphCarriesTheAttachmentAndKeepsItsLength() {
        let url = writePNG("pic.png", width: 200, height: 120)
        let c = make("![a picture](pic.png)\nafter\n")
        c.textView.setSelectedRange(NSRange(location: 22, length: 0))   // caret on "after"
        XCTAssertNotNil(waitForImage(c, url))

        let p = paragraph(c, line: 0)
        let source = "![a picture](pic.png)\n"
        XCTAssertEqual(p.length, source.utf16.count, "display paragraph stays length-identical (M0)")
        XCTAssertEqual(p.string.utf16.first, 0xFFFC, "the `!` is the attachment character")
        let a = p.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        XCTAssertNotNil(a, "attachment on the first character")
        XCTAssertEqual(a?.bounds.size, CGSize(width: 200, height: 120), "natural size fits in a 600pt column")
        // The rest of the construct is concealed.
        let f = p.attribute(.font, at: 5, effectiveRange: nil) as? NSFont
        XCTAssertEqual(f?.pointSize, Theme.concealedFont.pointSize)
        // The line is as tall as the image, not the image times the line-height multiple.
        let h = fragmentHeight(c, line: 0)
        XCTAssertGreaterThanOrEqual(h, 120)
        XCTAssertLessThan(h, 120 * 1.3)
    }

    func testRevealedImageParagraphShowsSourceAndNoImage() {
        let url = writePNG("pic.png", width: 200, height: 120)
        let c = make("![a picture](pic.png)\nafter\n")
        c.textView.setSelectedRange(NSRange(location: 22, length: 0))
        XCTAssertNotNil(waitForImage(c, url))
        c.textView.setSelectedRange(NSRange(location: 3, length: 0))   // caret into the image line
        let p = paragraph(c, line: 0)
        XCTAssertEqual(p.string, "![a picture](pic.png)\n")
        XCTAssertNil(p.attribute(.attachment, at: 0, effectiveRange: nil))
        XCTAssertLessThan(fragmentHeight(c, line: 0), 60, "the image is gone from the revealed line")
    }

    func testImageIsScaledDownToTheColumn() {
        let url = writePNG("wide.png", width: 1000, height: 500)
        let c = make("![w](wide.png)\nafter\n", width: 400)
        c.textView.setSelectedRange(NSRange(location: 16, length: 0))
        XCTAssertNotNil(waitForImage(c, url))
        let a = paragraph(c, line: 0).attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        let column = c.textContainer.size.width
        XCTAssertGreaterThan(column, 100)
        XCTAssertEqual(a?.bounds.width ?? 0, column, accuracy: 0.5)
        XCTAssertEqual(a?.bounds.height ?? 0, column / 2, accuracy: 0.5, "aspect ratio kept")
    }

    func testListItemImageFitsBesideTheIndent() {
        let url = writePNG("wide.png", width: 1000, height: 500)
        let c = make("- ![w](wide.png)\nafter\n", width: 400)
        c.textView.setSelectedRange(NSRange(location: 18, length: 0))
        XCTAssertNotNil(waitForImage(c, url))
        let a = paragraph(c, line: 0).attribute(.attachment, at: 2, effectiveRange: nil) as? NSTextAttachment
        let d = c.engine.decoration(forParagraphAt: 0)
        XCTAssertEqual(a?.bounds.width ?? 0, c.textContainer.size.width - d.headIndent, accuracy: 0.5)
    }

    func testTheImageIsActuallyDrawn() {
        writePNG("pic.png", width: 200, height: 120, color: .red)
        let c = make("![a picture](pic.png)\nafter\n")
        c.textView.setSelectedRange(NSRange(location: 22, length: 0))
        XCTAssertNotNil(waitForImage(c, dir.appendingPathComponent("pic.png")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        c.scrollView.layoutSubtreeIfNeeded()
        c.layoutManager.textViewportLayoutController.layoutViewport()
        let rep = c.scrollView.bitmapImageRepForCachingDisplay(in: c.scrollView.bounds)!
        c.scrollView.cacheDisplay(in: c.scrollView.bounds, to: rep)
        var red = 0
        for y in stride(from: 0, to: Int(rep.pixelsHigh), by: 4) {
            for x in stride(from: 0, to: Int(rep.pixelsWide), by: 4) {
                if let col = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), col.redComponent > 0.8, col.greenComponent < 0.3, col.blueComponent < 0.3 { red += 1 }
            }
        }
        XCTAssertGreaterThan(red, 100, "the red bitmap must reach the screen")
    }

    func testLoadCompletionRebuildsTheParagraph() {
        let url = writePNG("pic.png", width: 200, height: 120)
        let c = make("![a picture](pic.png)\nafter\n")
        c.textView.setSelectedRange(NSRange(location: 22, length: 0))
        // First build: the loader has not answered yet, so a placeholder stands in.
        let before = paragraph(c, line: 0).attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        XCTAssertNotNil(before)
        XCTAssertNotNil(waitForImage(c, url))
        let after = paragraph(c, line: 0).attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        XCTAssertEqual(after?.bounds.size, CGSize(width: 200, height: 120), "the real image replaced the placeholder")
    }

    // MARK: - Placeholders and modes

    func testMissingFileShowsAPlaceholderNotNothing() {
        let c = make("![gone](nope.png)\nafter\n")
        c.textView.setSelectedRange(NSRange(location: 20, length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let a = paragraph(c, line: 0).attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        XCTAssertNotNil(a)
        XCTAssertGreaterThan(a?.bounds.width ?? 0, 20)
    }

    func testRemoteImagesAreNotFetchedByDefault() {
        let c = make("![web](https://example.invalid/a.png)\nafter\n")
        c.textView.setSelectedRange(NSRange(location: 40, length: 0))
        _ = paragraph(c, line: 0)
        XCTAssertEqual(c.images.image(for: URL(string: "https://example.invalid/a.png")!), .remote)
        let a = paragraph(c, line: 0).attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        XCTAssertNotNil(a, "a placeholder pill stands in")
    }

    func testRawModeShowsSource() {
        let url = writePNG("pic.png", width: 200, height: 120)
        let c = make("![a picture](pic.png)\nafter\n")
        c.textView.setSelectedRange(NSRange(location: 22, length: 0))
        XCTAssertNotNil(waitForImage(c, url))
        c.mode = .raw
        let p = paragraph(c, line: 0)
        XCTAssertEqual(p.string, "![a picture](pic.png)\n")
        XCTAssertNil(p.attribute(.attachment, at: 0, effectiveRange: nil))
    }

    func testViewModeNeverRevealsTheImage() {
        let url = writePNG("pic.png", width: 200, height: 120)
        let c = make("![a picture](pic.png)\nafter\n")
        c.mode = .view
        c.textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertNotNil(waitForImage(c, url))
        XCTAssertNotNil(paragraph(c, line: 0).attribute(.attachment, at: 0, effectiveRange: nil))
    }

    func testUntitledDocumentCannotResolveRelativePaths() {
        writePNG("pic.png", width: 200, height: 120)
        let c = EditorController(textStorage: NSTextStorage(string: "![a](pic.png)\nafter\n"))
        c.textView.setSelectedRange(NSRange(location: 15, length: 0))
        let a = paragraph(c, line: 0).attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        XCTAssertNotNil(a, "placeholder")
        XCTAssertNotEqual(a?.bounds.size, CGSize(width: 200, height: 120))
    }

    // MARK: - Export

    func testRichTextExportEmbedsLocalImages() {
        writePNG("pic.png", width: 200, height: 120)
        let rich = RichTextExporter.attributedString(markdown: "Before ![alt](pic.png) after", baseURL: dir.appendingPathComponent("doc.md"), maxImageWidth: 100)
        var found: NSTextAttachment?
        rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length)) { v, _, _ in if let a = v as? NSTextAttachment { found = a } }
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.bounds.width ?? 0, 100, accuracy: 0.5)
        XCTAssertEqual(found?.bounds.height ?? 0, 60, accuracy: 0.5)
        XCTAssertTrue(rich.string.hasPrefix("Before "))
        XCTAssertTrue(rich.string.hasSuffix(" after"))
    }

    func testRichTextExportFallsBackToAltText() {
        let rich = RichTextExporter.attributedString(markdown: "![alt text](https://example.invalid/a.png)")
        XCTAssertEqual(rich.string, "alt text")
    }
}

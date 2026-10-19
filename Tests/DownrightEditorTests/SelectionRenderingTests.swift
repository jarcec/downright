import XCTest
import AppKit
@testable import DownrightEditor

/// The selection must show over anything that paints a background behind the text:
/// code spans, code blocks, quotes.
@MainActor
final class SelectionRenderingTests: XCTestCase {
    private let text = "Plain only) and `CREATE OR ALTER MATERIALIZED TABLE` (same\n\n```sql\nSELECT * FROM t\n```\n\n> quoted words here\n"

    /// Renders the editor with `selection` selected (a bare caret in the same place for the
    /// baseline, so the same markers are revealed); returns the bitmap and the
    /// selection's first rectangle in the bitmap's pixels.
    private func render(selecting selection: NSRange, measuring probe: NSRange) throws -> (NSBitmapImageRep, NSRect) {
        let c = EditorController(textStorage: NSTextStorage(string: text))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = window.contentView!.bounds
        c.textView.setSelectedRange(selection)
        c.scrollView.layoutSubtreeIfNeeded()
        let start = try XCTUnwrap(c.caretRect(at: probe.location)), end = try XCTUnwrap(c.caretRect(at: probe.upperBound))
        let rect = c.textView.convert(NSRect(x: start.minX, y: start.minY, width: end.minX - start.minX, height: start.height), to: c.scrollView)
        let rep = try XCTUnwrap(c.scrollView.bitmapImageRepForCachingDisplay(in: c.scrollView.bounds))
        c.scrollView.cacheDisplay(in: c.scrollView.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / c.scrollView.bounds.width
        return (rep, NSRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale))
    }

    /// Mean brightness of the pixels in `rect`.
    private func brightness(_ rep: NSBitmapImageRep, in rect: NSRect) -> CGFloat {
        var sum: CGFloat = 0, n: CGFloat = 0
        for y in stride(from: Int(rect.minY) + 2, to: Int(rect.maxY) - 2, by: 2) {
            for x in stride(from: Int(rect.minX) + 2, to: Int(rect.maxX) - 2, by: 2) {
                if let col = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) { sum += col.brightnessComponent; n += 1 }
            }
        }
        return n > 0 ? sum / n : 0
    }

    private func assertSelectionShows(_ needle: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let r = (text as NSString).range(of: needle)
        let (plain, rect) = try render(selecting: NSRange(location: r.location, length: 0), measuring: r)
        let (selected, _) = try render(selecting: r, measuring: r)
        XCTAssertGreaterThan(rect.width, 4, file: file, line: line)
        XCTAssertGreaterThan(brightness(plain, in: rect) - brightness(selected, in: rect), 0.03,
                             "selecting \"\(needle)\" must visibly tint it", file: file, line: line)
    }

    func testSelectionShowsOverPlainText() throws { try assertSelectionShows("only) and") }
    func testSelectionShowsOverInlineCode() throws { try assertSelectionShows("OR ALTER") }
    func testSelectionShowsOverCodeBlock() throws { try assertSelectionShows("* FROM") }
    func testSelectionShowsOverQuote() throws { try assertSelectionShows("quoted") }
}

import XCTest
import AppKit
import MarkdownKit
@testable import DownrightEditor

/// TeX typeset by MathJax in JavaScriptCore, drawn while the caret is elsewhere.
@MainActor
final class MathTests: XCTestCase {
    static let text = """
        Euler's identity, $e^{i\\pi} + 1 = 0$, ties five constants together. Sums like $\\sum_{k=1}^{n} k$ sit in the line.

        $$
        \\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}
        $$

        ## The quadratic formula $x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}$

        ```math
        \\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}
        ```

        Broken: $\\frac{1}{$ and prices like $5 and $10 stay text.

        """

    private func editor(_ text: String = text, theme: Theme = Theme()) -> (EditorController, NSWindow) {
        let c = EditorController(textStorage: NSTextStorage(string: text), theme: theme)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = window.contentView!.bounds
        c.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        window.layoutIfNeeded()
        c.scrollView.layoutSubtreeIfNeeded()
        return (c, window)
    }

    func testRendererTypesetsAndReportsErrors() {
        let r = MathRenderer()
        guard case .rendered(let f) = r.formula("\\frac{a}{b}", display: false, color: .black, fontSize: 15) else { return XCTFail("not typeset") }
        XCTAssertGreaterThan(f.image.size.height, 15, "a fraction stands taller than the text")
        XCTAssertGreaterThan(f.descent, 2, "and reaches below the baseline")
        guard case .failed(let message) = r.formula("\\frac{1}{", display: false, color: .black, fontSize: 15) else { return XCTFail("should fail") }
        XCTAssertFalse(message.isEmpty)
    }

    func testInlineFormulaReplacesItsSourceUntilTheCaretComesIn() {
        let (c, _) = editor()
        let ns = Self.text as NSString
        let at = ns.range(of: "$e^").location
        let d = c.engine.decoration(forParagraphAt: at)
        XCTAssertTrue(d.substitutions.contains { $0.offset == at && $0.char == 0xFFFC }, "the $ carries the formula")
        XCTAssertTrue(d.conceal.contains { $0.location == at + 1 }, "the TeX hides")
        let broken = ns.range(of: "$\\frac{1}{$").location
        let bd = c.engine.decoration(forParagraphAt: broken)
        XCTAssertFalse(bd.substitutions.contains { $0.offset == broken }, "TeX that fails stays source")
        XCTAssertTrue(bd.styles.contains { if case .toolTip(let t) = $0.op { return $0.range.location == broken && !t.isEmpty }; return false })
    }

    func testDisplayBlockIsCentredAndCollapses() {
        let (c, _) = editor()
        let ns = Self.text as NSString
        let fence = ns.range(of: "$$\n\\int").location
        let d = c.engine.decoration(forParagraphAt: fence)
        XCTAssertEqual(d.role, .diagramFence(info: "math"))
        XCTAssertEqual(d.concealedAlignment, .center)
        XCTAssertEqual(c.engine.decoration(forParagraphAt: ns.range(of: "\\int").location).role, .diagramSource(closing: false))
    }

    func testRichTextCarriesFormulasAsPictures() {
        let rich = RichTextExporter.attributedString(markdown: "Area $\\pi r^2$.\n\n$$\nx^2\n$$\n")
        var attachments = 0
        rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length)) { v, _, _ in if v != nil { attachments += 1 } }
        XCTAssertEqual(attachments, 2)
        XCTAssertFalse(rich.string.contains("\\pi"))
    }

    func testSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["SNAPSHOTS"] else { return }
        for (name, palette) in [("math-paper", Palette.paper), ("math-ink", Palette.ink)] {
            var theme = Theme(); theme.palette = palette
            let (c, _) = editor(theme: theme)
            let rep = try XCTUnwrap(c.scrollView.bitmapImageRepForCachingDisplay(in: c.scrollView.bounds))
            c.scrollView.cacheDisplay(in: c.scrollView.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}

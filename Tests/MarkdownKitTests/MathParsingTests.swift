import XCTest
@testable import MarkdownKit

/// GitHub's math syntax.
final class MathParsingTests: XCTestCase {
    /// The inline math nodes of the first paragraph: (display, TeX).
    private func math(_ text: String) -> [(Bool, String)] {
        let doc = MarkdownParser.parse(text)
        let ns = text as NSString
        guard let p = doc.blocks.first else { return [] }
        return p.inlines.compactMap { n in
            guard case .math(let display) = n.kind else { return nil }
            return (display, ns.substring(with: NSRange(n.markerRanges[0].end, to: n.markerRanges[1].location)))
        }
    }

    func testInlineMath() {
        XCTAssertEqual(math("Euler: $e^{i\\pi} + 1 = 0$ holds.\n").map(\.1), ["e^{i\\pi} + 1 = 0"])
        XCTAssertEqual(math("$a_1$ and $b_2$\n").map(\.1), ["a_1", "b_2"], "underscores belong to the TeX, not emphasis")
        XCTAssertEqual(math("Escaped \\$ inside $x \\$ y$ ok\n").map(\.1), ["x \\$ y"])
        XCTAssertEqual(math("Quoted $`a $ b`$ form\n").map(\.1), ["a $ b"])
    }

    func testPricesStayText() {
        XCTAssertTrue(math("It costs $5 and $10 today.\n").isEmpty)
        XCTAssertTrue(math("Pay $ 5 $ now\n").isEmpty, "no space just inside the dollars")
        XCTAssertTrue(math("From $3 to $4.\n").isEmpty)
        XCTAssertTrue(math("A lone $ sign\n").isEmpty)
    }

    func testDisplayMathInline() {
        let m = math("Then $$\\sum_{k=1}^n k$$ follows.\n")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.0, true)
        XCTAssertEqual(m.first?.1, "\\sum_{k=1}^n k")
    }

    func testCodeSpansStillWin() {
        XCTAssertTrue(math("Use `$x$` literally\n").isEmpty)
    }

    func testDollarFencesMakeAMathBlock() {
        let text = "Before\n\n$$\n\\frac{a}{b}\n$$\n\nAfter\n"
        let doc = MarkdownParser.parse(text)
        guard case .fencedCode(_, let close, let info) = doc.blocks[1].kind else { return XCTFail(doc.dump(source: text)) }
        XCTAssertEqual(info, "math")
        XCTAssertNotNil(close)
        XCTAssertEqual(doc.blocks[1].contentRanges.map { (text as NSString).substring(with: $0) }, ["\\frac{a}{b}"])
        XCTAssertEqual(doc.blocks.count, 3)
    }

    func testCommonMarkHasNoMath() {
        let doc = MarkdownParser.parse("$x$\n", dialect: .commonMark)
        XCTAssertFalse(doc.blocks[0].inlines.contains { if case .math = $0.kind { return true } else { return false } })
    }

    func testDetectionAndCounts() {
        let text = "Area $\\pi r^2$ of a circle.\n"
        let doc = MarkdownParser.parse(text)
        XCTAssertTrue(DetectedDialect.detect(in: doc).math)
        XCTAssertEqual(Document.counts(of: doc.proseRuns(), in: text as NSString).words, 4, "formulas are not words")
    }
}

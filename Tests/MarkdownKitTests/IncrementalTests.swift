import XCTest
@testable import MarkdownKit

final class IncrementalTests: XCTestCase {
    /// Apply `edit` (replace `range` in `old` with `text`) and reparse both ways.
    private func check(_ old: String, replace range: NSRange, with text: String, file: StaticString = #filePath, line: UInt = #line) {
        let oldDoc = MarkdownParser.parse(old)
        let new = (old as NSString).replacingCharacters(in: range, with: text)
        let delta = text.utf16.count - range.length
        let inc = MarkdownParser.reparse(previous: oldDoc, source: new, edit: NSRange(location: range.location, length: text.utf16.count), delta: delta)
        let full = MarkdownParser.parse(new)
        XCTAssertEqual(inc.dump(source: new), full.dump(source: new), "edit \(range) → \(text.debugDescription) in \(old.debugDescription)", file: file, line: line)
        XCTAssertEqual(inc.length, full.length, file: file, line: line)
    }

    func testTypingInsideParagraph() {
        check("# A\n\npara one\n\n# B\n\nmore\n", replace: NSRange(location: 9, length: 0), with: "X")
    }

    func testNewSetextUnderlineChangesPreviousBlock() {
        check("# A\n\npara\n\n# B\n", replace: NSRange(location: 9, length: 0), with: "\n---")
    }

    func testJoiningTwoLists() {
        check("# T\n\n- a\n- b\n\nx\n\n- c\n- d\n\nend\n", replace: NSRange(location: 14, length: 1), with: "")
    }

    func testOpeningAFenceSwallowsTheRest() {
        check("# T\n\npara\n\nmore\n\n# H\n", replace: NSRange(location: 5, length: 0), with: "```\n")
    }

    func testEditAtEndAndStart() {
        check("# T\n\npara\n", replace: NSRange(location: 10, length: 0), with: "tail")
        check("# T\n\npara\n", replace: NSRange(location: 0, length: 0), with: "---\nx: 1\n---\n")
    }

    func testLinkReferenceDefinitionForcesFullParse() {
        check("# T\n\n[r]: /u\n\nsee [r]\n", replace: NSRange(location: 10, length: 1), with: "v")
        check("# T\n\nsee [r]\n\n[r]: /u\n", replace: NSRange(location: 6, length: 0), with: "x ")
    }

    func testTableEdits() {
        check("# T\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nend\n", replace: NSRange(location: 28, length: 1), with: "**1**")
    }

    // Randomised equivalence: incremental must equal full parse for arbitrary edits.
    func testRandomEditsMatchFullParse() {
        var rng = SystemRandomNumberGenerator()
        let fragments = ["# Head\n", "## Sub\n", "para text **b** *i* `c` [l](u)\n", "\n", "- item\n", "  - nested\n", "1. one\n", "> quote\n", "```\ncode\n```\n",
                         "---\n", "| a | b |\n|---|---|\n| 1 | 2 |\n", "[r]: /url\n", "see [r] here\n", "    indented\n", "text  \nbreak\n", "<div>\nhtml\n</div>\n"]
        let inserts = ["x", "\n", "#", "# ", "-", "- ", "```", "```\n", "*", "**", "|", ">", "    ", "\n\n", "[r]", "1. ", "`", "\\"]
        for iteration in 0..<1500 {
            var doc = ""
            for _ in 0..<Int.random(in: 1...12, using: &rng) { doc += fragments.randomElement(using: &rng)! }
            let ns = doc as NSString
            let loc = Int.random(in: 0...ns.length, using: &rng)
            let len = Int.random(in: 0...min(6, ns.length - loc), using: &rng)
            let text = Bool.random(using: &rng) ? inserts.randomElement(using: &rng)! : ""
            let oldDoc = MarkdownParser.parse(doc)
            let new = ns.replacingCharacters(in: NSRange(location: loc, length: len), with: text)
            let delta = text.utf16.count - len
            let inc = MarkdownParser.reparse(previous: oldDoc, source: new, edit: NSRange(location: loc, length: text.utf16.count), delta: delta)
            let full = MarkdownParser.parse(new)
            if inc.dump(source: new) != full.dump(source: new) {
                XCTFail("iteration \(iteration): mismatch for \(doc.debugDescription) edit \(loc)+\(len) → \(text.debugDescription)\nINC:\n\(inc.dump(source: new))\nFULL:\n\(full.dump(source: new))")
                return
            }
        }
    }

    func testIncrementalPerformance() {
        let unit = "# Section\nSome **bold** text and a [link](http://x) in prose that goes on.\n- a\n- b\n\n```swift\nlet x = 1\n```\n\n"
        var s = ""
        while s.utf16.count < 1_000_000 { s += unit }
        let doc = MarkdownParser.parse(s)
        let loc = s.utf16.count / 2 + 20
        let new = (s as NSString).replacingCharacters(in: NSRange(location: loc, length: 0), with: "x")
        let t = Date()
        let inc = MarkdownParser.reparse(previous: doc, source: new, edit: NSRange(location: loc, length: 1), delta: 1)
        let ms = Date().timeIntervalSince(t) * 1000
        print("INCREMENTAL 1 MB single-char edit: \(String(format: "%.1f", ms)) ms (debug)")
        XCTAssertEqual(inc.blocks.count, doc.blocks.count)
        XCTAssertLessThan(ms, 400)   // debug build; release is ~10x faster. Dominated by tail shifting + utf16 copy.
    }
}

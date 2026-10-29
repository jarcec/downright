import XCTest
@testable import MarkdownKit

/// Counting the text a reader sees, not its syntax.
final class ProseTests: XCTestCase {
    private func counts(_ text: String, within clip: NSRange? = nil) -> ProseCounts {
        let doc = MarkdownParser.parse(text)
        return Document.counts(of: doc.proseRuns(), in: text as NSString, within: clip)
    }

    func testSyntaxIsNotCounted() {
        XCTAssertEqual(counts("# Big title\n\nSome **bold** and *it*.\n").words, 6)
        XCTAssertEqual(counts("See [the docs](https://example.com/very/long/path \"Title\") now.\n").words, 4)
        XCTAssertEqual(counts("- [ ] one\n- [x] two\n\n> quoted words here\n").words, 5)
        XCTAssertEqual(counts("| Name | Role |\n|---|---|\n| Ada | Maths |\n").words, 4)
        XCTAssertEqual(counts("---\ntitle: Hidden\n---\n\nShown.\n").words, 1)
        XCTAssertEqual(counts("Text <span class=\"x\">inside</span> ![an image](a.png) end.\n").words, 3, "tags and images are not read")
        XCTAssertEqual(counts("[ref]: https://example.com\n\nOne.\n").words, 1)
    }

    func testMarkersInsideAWordKeepItOneWord() {
        XCTAssertEqual(counts("un**believ**able don't e-mail\n").words, 3)
    }

    func testCodeCountsButDiagramsDoNot() {
        XCTAssertEqual(counts("```swift\nlet x = 1\n```\n").words, 3)
        XCTAssertEqual(counts("```mermaid\ngraph TD; A-->B\n```\n").words, 0)
    }

    func testCharactersAreWhatShows() {
        XCTAssertEqual(counts("**ab** c\n").characters, 4)
        XCTAssertEqual(counts("é👍🏽\n").characters, 2, "grapheme clusters, not UTF-16 units")
    }

    func testIdeographsCountOneEach() {
        XCTAssertEqual(counts("日本語のテキスト and English\n").words, 10)
    }

    func testASelectionCountsOnlyItself() {
        let text = "One two three.\n\nFour **five** six.\n"
        let ns = text as NSString
        let sel = NSRange(location: ns.range(of: "two").location, length: ns.range(of: "five").end - ns.range(of: "two").location)
        XCTAssertEqual(counts(text, within: sel), ProseCounts(words: 4, characters: 19))
    }

    func testReadingTime() {
        XCTAssertEqual(ProseCounts.readingMinutes(words: 0), 0)
        XCTAssertEqual(ProseCounts.readingMinutes(words: 1), 1)
        XCTAssertEqual(ProseCounts.readingMinutes(words: 230), 1)
        XCTAssertEqual(ProseCounts.readingMinutes(words: 231), 2)
    }
}

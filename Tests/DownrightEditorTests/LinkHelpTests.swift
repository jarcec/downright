import XCTest
import AppKit
import MarkdownKit
@testable import DownrightEditor

/// Links that lead nowhere are marked, and destinations are offered while one is typed.
@MainActor
final class LinkHelpTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("downright-linkhelp-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("guides/deep", isDirectory: true), withIntermediateDirectories: true)
        try "# Setup Notes\n\n## Install\n".write(to: dir.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)
        try "# Guide\n".write(to: dir.appendingPathComponent("guides/start here.md"), atomically: true, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent("picture.png"))
        try "".write(to: dir.appendingPathComponent("doc.md"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent(".hidden.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func make(_ text: String, titled: Bool = true) -> EditorController {
        let c = EditorController(textStorage: NSTextStorage(string: text))
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        if titled { c.baseURL = dir.appendingPathComponent("doc.md") }
        return c
    }

    /// The problem the link on the line starting at `needle` is marked with, if any.
    private func problem(_ c: EditorController, _ needle: String) -> String? {
        let at = (c.textStorage.string as NSString).range(of: needle).location
        let d = c.engine.decoration(forParagraphAt: at)
        guard d.styles.contains(where: { if case .underline = $0.op { return $0.range.location == at }; return false }) else { return nil }
        for run in d.styles where run.range.location == at { if case .toolTip(let t) = run.op { return t } }
        return "?"
    }

    func testBrokenLinksAreMarkedAndGoodOnesAreNot() {
        let c = make("""
            # Intro
            # Intro

            [a](#intro) [b](#intro-1) [c](#Intro) [d](#missing)
            [e](other.md) [f](other.md#install) [g](other.md#setup-notes) [h](other.md#nope)
            [i](gone.md) [j](guides/start%20here.md) [k](https://example.com/x) [l](guides/)

            """)
        for good in ["[a]", "[b]", "[c]", "[e]", "[f]", "[g]", "[j]", "[k]", "[l]"] {
            XCTAssertNil(problem(c, good), good)
        }
        XCTAssertEqual(problem(c, "[d]"), "#missing\nNo heading “#missing” in this document")
        XCTAssertEqual(problem(c, "[h]"), "other.md#nope\nNo heading “#nope” in other.md")
        XCTAssertTrue(problem(c, "[i]")?.contains("Nothing at") == true)
    }

    func testAnUntitledDocumentOnlyChecksItsOwnAnchors() {
        let c = make("[a](gone.md) [b](#nowhere)\n", titled: false)
        XCTAssertNil(problem(c, "[a]"), "nothing to resolve a path against")
        XCTAssertNotNil(problem(c, "[b]"))
    }

    func testRepeatedHeadingsGetNumberedAnchors() {
        let doc = MarkdownParser.parse("# Intro\n## Intro\n# Other *thing*\n")
        XCTAssertEqual(doc.headingAnchors().map(\.slug), ["intro", "intro-1", "other-thing"])
        let c = make("# Intro\n\ntext\n\n# Intro\n\nmore\n")
        XCTAssertTrue(c.scroll(toHeading: "intro-1"))
        XCTAssertEqual(c.textView.selectedRange().location, (c.textStorage.string as NSString).range(of: "# Intro\n\nmore").location)
    }

    func testTheDestinationBeingTyped() {
        let c = make("See [docs](gui and `[x](no` and [y](a b\n")
        let s = c.textStorage.string as NSString
        let typed = s.range(of: "gui")
        XCTAssertEqual(c.linkDestination(endingAt: typed.end), typed)
        XCTAssertEqual(c.linkDestination(endingAt: typed.location), NSRange(location: typed.location, length: 0), "just after ](")
        XCTAssertNil(c.linkDestination(endingAt: s.range(of: "no`").end - 1), "not in code")
        XCTAssertNil(c.linkDestination(endingAt: s.range(of: "a b").end), "a space ends a destination")
        XCTAssertNil(c.linkDestination(endingAt: s.range(of: "See").end))
    }

    func testFilesAreOffered() {
        let c = make("x\n")
        XCTAssertEqual(c.linkCompletions(for: ""), ["other.md", "picture.png", "guides/"], "Markdown first, then files, then folders; hidden and own left out")
        XCTAssertEqual(c.linkCompletions(for: "o"), ["other.md"])
        XCTAssertEqual(c.linkCompletions(for: "guides/"), ["guides/start%20here.md", "guides/deep/"])
        XCTAssertEqual(c.linkCompletions(for: "guides/start%20"), ["guides/start%20here.md"])
        XCTAssertTrue(make("x\n", titled: false).linkCompletions(for: "").isEmpty)
    }

    func testHeadingsAreOffered() {
        let c = make("# Getting Started\n\n## Build from source\n\n[x](\n")
        XCTAssertEqual(c.linkCompletions(for: "#"), ["#getting-started", "#build-from-source"])
        XCTAssertEqual(c.linkCompletions(for: "#bu"), ["#build-from-source"])
        XCTAssertEqual(c.linkCompletions(for: "#source"), ["#build-from-source"], "words of the title match too")
        XCTAssertEqual(c.linkCompletions(for: "other.md#"), ["other.md#setup-notes", "other.md#install"])
    }

    func testTheTextViewOffersThemThroughItsCompletion() {
        let c = make("[x](o\n")
        c.textView.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertEqual(c.textView.rangeForUserCompletion, NSRange(location: 4, length: 1))
        var index = 0
        XCTAssertEqual(c.textView.completions(forPartialWordRange: NSRange(location: 4, length: 1), indexOfSelectedItem: &index), ["other.md"])
        XCTAssertEqual(index, -1, "nothing is chosen until the arrow keys choose it")
    }
}

extension LinkHelpTests {
    func testSnapshot() throws {
        guard let snaps = ProcessInfo.processInfo.environment["SNAPSHOTS"] else { return }
        let c = make("# Intro\n\nSee [the install notes](other.md#install), [a missing section](#nowhere) and [a gone file](gone.md).\n\nEnd.\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = window.contentView!.bounds
        c.textView.setSelectedRange(NSRange(location: c.textStorage.length, length: 0))
        window.layoutIfNeeded()
        c.scrollView.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(c.scrollView.bitmapImageRepForCachingDisplay(in: c.scrollView.bounds))
        c.scrollView.cacheDisplay(in: c.scrollView.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(snaps)/links.png"))
    }
}

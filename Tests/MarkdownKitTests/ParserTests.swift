import XCTest
@testable import MarkdownKit

final class ParserTests: XCTestCase {
    private func dump(_ s: String) -> String { MarkdownParser.parse(s).dump(source: s) }

    func testHeadingAndInlines() {
        XCTAssertEqual(dump("# Heading one\nSome **bold** and *em* and `code` text.\n"), """
        heading1 0..<14 markers=0+2
          text 2..<13 "Heading one"
        paragraph 14..<54
          text 14..<19 "Some "
          strong 19..<27 markers=19+2,25+2
            text 21..<25 "bold"
          text 27..<32 " and "
          em 32..<36 markers=32+1,35+1
            text 33..<35 "em"
          text 36..<41 " and "
          code 41..<47 markers=41+1,46+1
          text 47..<53 " text."

        """)
    }

    func testSetextVersusThematicBreak() {
        XCTAssertEqual(dump("Setext\n===\n\nFoo\n---\n\n---\n"), """
        setext1 0..<11 markers=7+3
          text 0..<6 "Setext"
        setext2 12..<20 markers=16+3
          text 12..<15 "Foo"
        hr 21..<25 markers=21+3

        """)
    }

    func testNestedTightList() {
        XCTAssertEqual(dump("- a\n- b\n  - nested\n- c\n"), """
        list(bullet,tight) 0..<23
          item(indent=2) 0..<4 markers=0+1
            paragraph 0..<4
              text 2..<3 "a"
          item(indent=2) 4..<19 markers=4+1
            paragraph 4..<8
              text 6..<7 "b"
            list(bullet,tight) 8..<19
              item(indent=2) 8..<19 markers=10+1
                paragraph 8..<19
                  text 12..<18 "nested"
          item(indent=2) 19..<23 markers=19+1
            paragraph 19..<23
              text 21..<22 "c"

        """)
    }

    func testLooseLists() {
        XCTAssertTrue(dump("- a\n\n- b\n").hasPrefix("list(bullet,loose)"))
        XCTAssertTrue(dump("- item\n\n  second para\n- next\n").hasPrefix("list(bullet,loose)"))
        XCTAssertTrue(dump("1. one\n2. two\n\n   para in two\n3. three\n").hasPrefix("list(ordered@1,loose)"))
        XCTAssertTrue(dump("- a\n  - b\n\n  - c\n- d\n").hasPrefix("list(bullet,tight)"), "blank inside nested list must not loosen the outer list")
    }

    func testTaskItems() {
        XCTAssertEqual(dump("- [ ] todo\n- [x] done\n"), """
        list(bullet,tight) 0..<22
          item(indent=2,todo) 0..<11 markers=0+1,2+3
            paragraph 0..<11
              text 6..<10 "todo"
          item(indent=2,done) 11..<22 markers=11+1,13+3
            paragraph 11..<22
              text 17..<21 "done"

        """)
    }

    func testBlockQuoteWithLazyContinuation() {
        XCTAssertEqual(dump("> quote line\n> more\nlazy\n\nafter\n"), """
        quote 0..<25 markers=0+2,13+2
          paragraph 0..<25
            text 2..<12 "quote line"
            softbreak 12..<13
            text 15..<19 "more"
            softbreak 19..<20
            text 20..<24 "lazy"
        paragraph 26..<32
          text 26..<31 "after"

        """)
    }

    func testFences() {
        XCTAssertEqual(dump("```swift\nlet x = 1\n```\ntail\n"), """
        fence(swift) 0..<23 markers=0+8,19+3
        paragraph 23..<28
          text 23..<27 "tail"

        """)
        XCTAssertEqual(dump("~~~\nopen fence\n"), "fence()[open] 0..<15 markers=0+3\n")
        let d = MarkdownParser.parse("```\na\n\nb\n```\n")
        XCTAssertEqual(d.blocks.count, 1)
        XCTAssertEqual(d.blocks[0].contentRanges.count, 3, "blank lines inside a fence are content")
    }

    func testTableAndFrontmatter() {
        XCTAssertEqual(dump("| a | b |\n|---|:-:|\n| 1 | 2 |\nnot table\n"), "table 0..<40\n")
        XCTAssertEqual(dump("---\ntitle: x\n---\n# After\n"), """
        frontmatter 0..<17 markers=0+3,13+3
        heading1 17..<25 markers=17+2
          text 19..<24 "After"

        """)
    }

    func testHardBreaks() {
        XCTAssertEqual(dump("line one  \nline two\\\nline three\n"), """
        paragraph 0..<32
          text 0..<8 "line one"
          hardbreak 8..<11 markers=8+2
          text 11..<19 "line two"
          hardbreak 19..<21 markers=19+1
          text 21..<31 "line three"

        """)
    }

    func testLinksImagesReferences() {
        XCTAssertEqual(dump("[link](http://x.y \"t\") and [ref][r] and [r] and ![img](a.png)\n\n[r]: /url\n"), """
        paragraph 0..<62
          link(http://x.y) 0..<22 markers=0+1,5+17
            text 1..<5 "link"
          text 22..<27 " and "
          link(/url) 27..<35 markers=27+1,31+4
            text 28..<31 "ref"
          text 35..<40 " and "
          link(/url) 40..<43 markers=40+1,42+1
            text 41..<42 "r"
          text 43..<48 " and "
          image(a.png) 48..<61 markers=48+2,53+8
            text 50..<53 "img"
        linkref 63..<73

        """)
    }

    func testAutolinks() {
        XCTAssertEqual(dump("Visit https://example.com/path). ok <https://a.b> <me@x.org>\n"), """
        paragraph 0..<61
          text 0..<6 "Visit "
          autolink(https://example.com/path) 6..<30
          text 30..<36 "). ok "
          autolink(https://a.b) 36..<49 markers=36+1,48+1
          text 49..<50 " "
          autolink(mailto:me@x.org) 50..<60 markers=50+1,59+1

        """)
    }

    func testEmphasisRules() {
        XCTAssertEqual(dump("***bold-em*** __strong__ _em_ ~~del~~ a*b*c a_b_c\n"), """
        paragraph 0..<50
          em 0..<13 markers=0+1,12+1
            strong 1..<12 markers=1+2,10+2
              text 3..<10 "bold-em"
          text 13..<14 " "
          strong 14..<24 markers=14+2,22+2
            text 16..<22 "strong"
          text 24..<25 " "
          em 25..<29 markers=25+1,28+1
            text 26..<28 "em"
          text 29..<30 " "
          strike 30..<37 markers=30+2,35+2
            text 32..<35 "del"
          text 37..<39 " a"
          em 39..<42 markers=39+1,41+1
            text 40..<41 "b"
          text 42..<49 "c a_b_c"

        """)
    }

    func testStrayBracketsAndEscapes() {
        XCTAssertEqual(dump("Text with \\* escaped and a [bracket] alone and ] stray.\n"), """
        paragraph 0..<56
          text 0..<10 "Text with "
          escape 10..<12 markers=10+1
          text 12..<55 " escaped and a [bracket] alone and ] stray."

        """)
    }

    func testMiscBlocks() {
        XCTAssertEqual(dump("    indented code\n    more\n\npara\n"), "indented 0..<27\nparagraph 28..<33\n  text 28..<32 \"para\"\n")
        XCTAssertEqual(dump("<div>\nhtml\n</div>\n\ntext <span>inline</span>\n"), """
        html 0..<18
        paragraph 19..<44
          text 19..<24 "text "
          html 24..<30
          text 30..<36 "inline"
          html 36..<43

        """)
        XCTAssertEqual(dump("* * *\n\n-\n  after empty marker\n"), """
        hr 0..<6 markers=0+5
        list(bullet,tight) 7..<30
          item(indent=2) 7..<30 markers=7+1
            paragraph 9..<30
              text 11..<29 "after empty marker"

        """)
        XCTAssertEqual(dump("no trailing newline"), "paragraph 0..<19\n  text 0..<19 \"no trailing newline\"\n")
        XCTAssertEqual(dump(""), "")
        XCTAssertEqual(dump("\n\n"), "")
    }

    // MARK: - Structural invariants (plan §4 Phase 2e)

    func testRangeInvariants() {
        let corpus = [
            "# H\n\npara **b** _i_\n\n- a\n  - b\n\n> q\n> > qq\n\n```\ncode\n```\n\n| a |\n|---|\n| 1 |\n",
            "---\nx: 1\n---\n\n1. a\n2. b\n   - c\n\n[r]: /u\n[r] and [x][r] and ![i](p)\n",
            String(repeating: "*a* **b** ~~c~~ `d` [e](f) <g@h.i> https://j.k\n\n", count: 20),
        ]
        for src in corpus {
            let doc = MarkdownParser.parse(src)
            let len = src.utf16.count
            func check(_ blocks: [Block], within parent: NSRange) {
                var prevEnd = parent.location
                for b in blocks {
                    XCTAssertGreaterThanOrEqual(b.range.location, prevEnd, "siblings must be sorted and disjoint: \(b.kind.label)")
                    XCTAssertGreaterThanOrEqual(b.range.location, parent.location)
                    XCTAssertLessThanOrEqual(b.range.end, parent.end, "\(b.kind.label) exceeds parent")
                    for m in b.markerRanges {
                        XCTAssertGreaterThanOrEqual(m.location, b.range.location); XCTAssertLessThanOrEqual(m.end, b.range.end)
                    }
                    for c in b.contentRanges {
                        XCTAssertGreaterThanOrEqual(c.location, b.range.location); XCTAssertLessThanOrEqual(c.end, b.range.end)
                    }
                    checkInlines(b.inlines, within: b.range)
                    check(b.children, within: b.range)
                    prevEnd = b.range.end
                }
            }
            func checkInlines(_ nodes: [Inline], within parent: NSRange) {
                var prevEnd = parent.location
                for n in nodes {
                    XCTAssertGreaterThanOrEqual(n.range.location, prevEnd, "inline siblings overlap: \(n.kind.label) at \(n.range)")
                    XCTAssertLessThanOrEqual(n.range.end, parent.end)
                    for m in n.markerRanges {
                        XCTAssertGreaterThanOrEqual(m.location, n.range.location); XCTAssertLessThanOrEqual(m.end, n.range.end)
                    }
                    checkInlines(n.children, within: n.range)
                    prevEnd = n.range.end
                }
            }
            check(doc.blocks, within: NSRange(location: 0, length: len))
        }
    }

    func testPathLookup() {
        let src = "# H\n\n- a\n  - b\n\npara\n"
        let doc = MarkdownParser.parse(src)
        XCTAssertEqual(doc.path(containing: 0).map(\.kind.label), ["heading1"])
        XCTAssertEqual(doc.path(containing: 4).map(\.kind.label), [])   // blank line
        XCTAssertEqual(doc.path(containing: 11).map(\.kind.label), ["list(bullet,tight)", "item(indent=2)", "list(bullet,tight)", "item(indent=2)", "paragraph"])
        XCTAssertEqual(doc.path(containing: 16).map(\.kind.label), ["paragraph"])
    }

    func testParsePerformance() {
        let unit = "# Section\nSome **bold** text and a [link](http://x) in prose that goes on.\n- a\n- b\n\n```swift\nlet x = 1\n```\n\n"
        var s = ""
        while s.utf16.count < 1_000_000 { s += unit }
        let t = Date()
        let doc = MarkdownParser.parse(s)
        let ms = Date().timeIntervalSince(t) * 1000
        XCTAssertGreaterThan(doc.blocks.count, 1000)
        print("PARSE 1 MB: \(Int(ms)) ms (debug build)")
        XCTAssertLessThan(ms, 2000)
    }
}

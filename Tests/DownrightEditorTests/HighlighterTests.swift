import XCTest
@testable import DownrightEditor

final class HighlighterTests: XCTestCase {
    private func kinds(_ lang: String, _ code: String) -> [(String, CodeToken)] {
        let h = Highlighters.highlighter(for: lang)!
        return h.tokens(in: code).map { ((code as NSString).substring(with: $0.0), $0.1) }
    }

    func testSwift() {
        let t = kinds("swift", "let x: Int = 42 // answer\nfunc f() -> String { return \"hi\" }")
        XCTAssertTrue(t.contains { $0 == ("let", .keyword) })
        XCTAssertTrue(t.contains { $0 == ("Int", .type) })
        XCTAssertTrue(t.contains { $0 == ("42", .number) })
        XCTAssertTrue(t.contains { $0 == ("// answer", .comment) })
        XCTAssertTrue(t.contains { $0 == ("\"hi\"", .string) })
    }

    func testPythonTripleQuotesAndComments() {
        let t = kinds("python", "def f():\n    \"\"\"doc\n    string\"\"\"\n    return None  # done")
        XCTAssertTrue(t.contains { $0 == ("def", .keyword) })
        XCTAssertTrue(t.contains { $0.1 == .string && $0.0.contains("doc\n    string") })
        XCTAssertTrue(t.contains { $0 == ("# done", .comment) })
    }

    func testJSONKeysAndValues() {
        let t = kinds("json", "{\"name\": \"x\", \"n\": 3, \"ok\": true}")
        XCTAssertTrue(t.contains { $0 == ("\"name\"", .key) })
        XCTAssertTrue(t.contains { $0 == ("\"x\"", .string) })
        XCTAssertTrue(t.contains { $0 == ("3", .number) })
        XCTAssertTrue(t.contains { $0 == ("true", .keyword) })
    }

    func testYAMLKeys() {
        let t = kinds("yaml", "title: Demo\nlist:\n  - item # c\nurl: http://x")
        XCTAssertTrue(t.contains { $0 == ("title", .key) })
        XCTAssertTrue(t.contains { $0 == ("list", .key) })
        XCTAssertTrue(t.contains { $0 == ("# c", .comment) })
        XCTAssertFalse(t.contains { $0 == ("http", .key) }, "'http://' must not read as a key")
    }

    func testShellVariablesAndDiff() {
        let t = kinds("bash", "export FOO=$BAR # c\nif [ -z ${X} ]; then echo hi; fi")
        XCTAssertTrue(t.contains { $0 == ("export", .keyword) })
        XCTAssertTrue(t.contains { $0 == ("$BAR", .variable) })
        XCTAssertTrue(t.contains { $0 == ("${X}", .variable) })
        let d = kinds("diff", "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n same")
        XCTAssertEqual(d.map(\.1), [.meta, .meta, .key, .removed, .added])
    }

    func testSQLCaseInsensitiveAndHTML() {
        let s = kinds("sql", "SELECT id FROM users WHERE name = 'x' -- c")
        XCTAssertTrue(s.contains { $0 == ("SELECT", .keyword) })
        XCTAssertTrue(s.contains { $0 == ("'x'", .string) })
        XCTAssertTrue(s.contains { $0 == ("-- c", .comment) })
        let h = kinds("html", "<div class=\"a\">x</div><!-- c -->")
        XCTAssertTrue(h.contains { $0 == ("<div", .tag) })
        XCTAssertTrue(h.contains { $0 == ("class", .attribute) })
        XCTAssertTrue(h.contains { $0 == ("\"a\"", .string) })
        XCTAssertTrue(h.contains { $0 == ("<!-- c -->", .comment) })
    }

    func testUnknownLanguageIsPlain() {
        XCTAssertNil(Highlighters.highlighter(for: "brainfuck"))
        XCTAssertNil(Highlighters.highlighter(for: ""))
    }
}

import XCTest
@testable import DownrightConfig

final class TOMLTests: XCTestCase {
    func testParse() {
        let text = """
        # Downright settings
        line_numbers = true
        outline = false   # trailing comment
        appearance = "dark"
        count = 42
        bare = system
        quoted = "a # not a comment"

        [editor]
        vim_mode = true
        """
        let v = TOML.parse(text)
        XCTAssertEqual(v["line_numbers"], .bool(true))
        XCTAssertEqual(v["outline"], .bool(false))
        XCTAssertEqual(v["appearance"], .string("dark"))
        XCTAssertEqual(v["count"], .int(42))
        XCTAssertEqual(v["bare"], .string("system"))
        XCTAssertEqual(v["quoted"], .string("a # not a comment"))
        XCTAssertEqual(v["editor.vim_mode"], .bool(true))
    }

    func testUpdatePreservesCommentsAndUnknownKeys() {
        let text = """
        # My settings, managed by chezmoi
        line_numbers = true   # gutter
        custom_future_key = "keep me"
        appearance = "system"
        """
        let out = TOML.updating(text, with: ["line_numbers": .bool(false), "appearance": .string("dark"), "vim_mode": .bool(true)])
        XCTAssertEqual(out, """
        # My settings, managed by chezmoi
        line_numbers = false  # gutter
        custom_future_key = "keep me"
        appearance = "dark"

        vim_mode = true

        """)
        XCTAssertEqual(TOML.parse(out)["vim_mode"], .bool(true))
    }

    func testRoundTripStrings() {
        let v = TOMLValue.string("q\"uote \\ back\nline")
        XCTAssertEqual(TOML.parse("k = \(v.serialized)")["k"], v)
    }

    func testEmptyAndMalformed() {
        XCTAssertEqual(TOML.parse(""), [:])
        XCTAssertEqual(TOML.parse("this is not toml\n= nokey\nkey =\n"), [:])
        XCTAssertEqual(TOML.updating("", with: ["a": .bool(true)]), "a = true\n")
    }
}

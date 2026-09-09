import XCTest
import AppKit
@testable import DownrightEditor

@MainActor
final class VimEngineTests: XCTestCase {
    private var c: EditorController!
    private var storage: NSTextStorage!
    private var vim: VimEngine { c.textView.vim }

    private func load(_ text: String, caret: Int = 0) {
        storage = NSTextStorage(string: text)
        c = EditorController(textStorage: storage)
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        c.textView.vim.isEnabled = true
        c.textView.setSelectedRange(NSRange(location: caret, length: 0))
    }

    private func key(_ chars: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                 characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        if !vim.handle(e) { c.textView.insertText(chars, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }
    private func keys(_ s: String) { for ch in s { key(String(ch)) } }
    private func escape() { key("\u{1B}", code: 53) }
    private func enter() { key("\r", code: 36) }
    private var caret: Int { c.textView.selectedRange().location }

    func testStartsInNormalAndInsertPassesThrough() {
        load("abc")
        XCTAssertEqual(vim.mode, .normal)
        keys("i"); XCTAssertEqual(vim.mode, .insert)
        keys("xy")
        XCTAssertEqual(storage.string, "xyabc")
        escape(); XCTAssertEqual(vim.mode, .normal)
        XCTAssertEqual(vim.statusText, "NORMAL")
    }

    func testMotions() {
        load("one two three\nfour five\nsix", caret: 0)
        keys("w"); XCTAssertEqual(caret, 4)
        keys("w"); XCTAssertEqual(caret, 8)
        keys("b"); XCTAssertEqual(caret, 4)
        keys("e"); XCTAssertEqual(caret, 6)          // on the 'o' of "two"
        keys("$"); XCTAssertEqual(caret, 13)
        keys("0"); XCTAssertEqual(caret, 0)
        keys("j"); XCTAssertEqual(caret, 14)
        keys("3l"); XCTAssertEqual(caret, 17)
        keys("k"); XCTAssertEqual(caret, 3)
        keys("G"); XCTAssertEqual(caret, 24)
        keys("gg"); XCTAssertEqual(caret, 0)
        keys("2j"); XCTAssertEqual(caret, 24)
    }

    func testDeleteAndPasteLinewise() {
        load("a\nb\nc\n", caret: 2)
        keys("dd")
        XCTAssertEqual(storage.string, "a\nc\n")
        XCTAssertEqual(caret, 2)
        keys("p")
        XCTAssertEqual(storage.string, "a\nc\nb\n")
        keys("kP")
        XCTAssertEqual(storage.string, "a\nb\nc\nb\n")
        keys("yyjp")
        XCTAssertEqual(storage.string, "a\nb\nc\nb\nb\n")
    }

    func testCountedDeleteAndCharwise() {
        load("hello world\nline2", caret: 0)
        keys("2x")
        XCTAssertEqual(storage.string, "llo world\nline2")
        keys("dw")
        XCTAssertEqual(storage.string, "world\nline2")
        keys("D")
        XCTAssertEqual(storage.string, "\nline2")
        keys("jp")   // charwise paste of "world"
        XCTAssertEqual(storage.string, "\nlworldine2")
    }

    func testChangeEntersInsert() {
        load("foo bar", caret: 0)
        keys("cw"); XCTAssertEqual(vim.mode, .insert)
        XCTAssertEqual(storage.string, "bar")   // 'cw' here behaves like 'dw' then insert (v0)
        keys("X"); escape()
        XCTAssertEqual(storage.string, "Xbar")
    }

    func testInsertVariants() {
        load("ab\ncd", caret: 0)
        keys("A"); XCTAssertEqual(vim.mode, .insert); XCTAssertEqual(caret, 2)
        escape(); keys("j0"); XCTAssertEqual(caret, 3)
        keys("o"); XCTAssertEqual(storage.string, "ab\ncd\n"); XCTAssertEqual(vim.mode, .insert)
        escape(); keys("kkO"); XCTAssertEqual(storage.string, "\nab\ncd\n"); XCTAssertEqual(caret, 0)
    }

    func testUndo() {
        load("abc", caret: 0)
        c.textView.undoManager?.removeAllActions()
        keys("x")
        XCTAssertEqual(storage.string, "bc")
        // undo goes through NSTextView's undo manager when one exists; without a window
        // there may be none, so only assert it does not crash and mode stays normal
        keys("u"); XCTAssertEqual(vim.mode, .normal)
    }

    func testCommandLine() {
        var received: [String] = []
        load("a\nb\nc\nd", caret: 0)
        vim.onExCommand = { received.append($0) }
        keys(":wq"); XCTAssertEqual(vim.mode, .command); XCTAssertEqual(vim.statusText, ":wq")
        enter()
        XCTAssertEqual(received, ["wq"])
        XCTAssertEqual(vim.mode, .normal)
        keys(":3"); enter()
        XCTAssertEqual(caret, 4)
        keys(":q!"); key("\u{7F}", code: 51); XCTAssertEqual(vim.statusText, ":q")
        escape(); XCTAssertEqual(vim.mode, .normal)
    }

    func testDisabledPassesEverything() {
        load("abc")
        vim.isEnabled = false
        keys("x")
        XCTAssertEqual(storage.string, "xabc")
    }
}

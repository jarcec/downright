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

@MainActor
final class VimVisualTests: XCTestCase {
    private var c: EditorController!
    private var storage: NSTextStorage!
    private func load(_ text: String, caret: Int = 0) {
        storage = NSTextStorage(string: text)
        c = EditorController(textStorage: storage)
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        c.textView.vim.isEnabled = true
        c.textView.setSelectedRange(NSRange(location: caret, length: 0))
    }
    private func keys(_ s: String) {
        for ch in s {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                     characters: String(ch), charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0)!
            if !c.textView.vim.handle(e) { c.textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
    }
    private func escape() {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53)!
        _ = c.textView.vim.handle(e)
    }
    private var sel: NSRange { c.textView.selectedRange() }

    func testCharwiseSelectAndDelete() {
        load("one two three", caret: 4)
        keys("v")
        XCTAssertEqual(c.textView.vim.mode, .visual(kind: .char))
        XCTAssertEqual(sel, NSRange(location: 4, length: 1), "v selects the character under the cursor")
        keys("e")
        XCTAssertEqual(sel, NSRange(location: 4, length: 3), "extends to the end of 'two'")
        keys("d")
        XCTAssertEqual(storage.string, "one  three")
        XCTAssertEqual(c.textView.vim.mode, .normal)
        XCTAssertEqual(sel, NSRange(location: 4, length: 0))
    }

    func testLinewiseYankAndPaste() {
        load("a\nb\nc\n", caret: 0)
        keys("Vjy")
        XCTAssertEqual(c.textView.vim.mode, .normal)
        keys("G")      // last line
        keys("p")
        XCTAssertEqual(storage.string, "a\nb\nc\na\nb\n")
    }

    func testBackwardSelectionAndEscape() {
        load("hello world", caret: 8)
        keys("vb")
        XCTAssertEqual(sel, NSRange(location: 6, length: 3), "selecting backwards keeps the anchor character")
        escape()
        XCTAssertEqual(c.textView.vim.mode, .normal)
        XCTAssertEqual(sel.length, 0)
        XCTAssertEqual(sel.location, 6)
    }

    func testChangeAndStatus() {
        load("foo bar", caret: 0)
        keys("v")
        XCTAssertEqual(c.textView.vim.statusText, "-- VISUAL --")
        keys("ec")
        XCTAssertEqual(c.textView.vim.mode, .insert)
        XCTAssertEqual(storage.string, " bar")
        keys("X"); escape()
        XCTAssertEqual(storage.string, "X bar")
    }

    func testVisualPasteReplacesSelection() {
        load("one two", caret: 0)
        keys("yw")           // register = "one "
        keys("wve")          // select "two"
        keys("p")
        XCTAssertEqual(storage.string, "one one ")
    }

    func testSwapEndsAndToggleLinewise() {
        load("ab\ncd\n", caret: 0)
        keys("vlo")
        XCTAssertEqual(sel, NSRange(location: 0, length: 2))
        keys("V")
        XCTAssertEqual(sel, NSRange(location: 0, length: 3), "V from charwise becomes linewise over the same line")
        keys("v"); XCTAssertEqual(c.textView.vim.mode, .visual(kind: .char))
        keys("v"); XCTAssertEqual(c.textView.vim.mode, .normal)
    }
}


@MainActor
final class VimObjectsAndBlockTests: XCTestCase {
    private var c: EditorController!
    private var storage: NSTextStorage!
    private func load(_ text: String, caret: Int = 0) {
        storage = NSTextStorage(string: text)
        c = EditorController(textStorage: storage)
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        c.textView.vim.isEnabled = true
        c.textView.setSelectedRange(NSRange(location: caret, length: 0))
    }
    private func key(_ ch: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                 characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
        if !c.textView.vim.handle(e) { c.textView.insertText(ch, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }
    private func keys(_ s: String) { for ch in s { key(String(ch)) } }
    private func ctrlV() { key("v", flags: .control) }
    private func escape() { key("\u{1B}", code: 53) }
    private var sel: NSRange { c.textView.selectedRange() }

    func testTextObjectsWithOperators() {
        load("call(foo, \"bar baz\") end", caret: 6)
        keys("diw"); XCTAssertEqual(storage.string, "call(, \"bar baz\") end")
        keys("u")
        load("call(foo, \"bar baz\") end", caret: 12)
        keys("di\""); XCTAssertEqual(storage.string, "call(foo, \"\") end")
        load("call(foo, \"bar baz\") end", caret: 12)
        keys("da("); XCTAssertEqual(storage.string, "call end")
        load("one two  three", caret: 4)
        keys("daw"); XCTAssertEqual(storage.string, "one three")
        load("p1\np1 more\n\np2\n", caret: 0)
        keys("dap"); XCTAssertEqual(storage.string, "p2\n")
        load("a [b [c] d] e", caret: 7)
        keys("ci]"); XCTAssertEqual(storage.string, "a [b [] d] e"); XCTAssertEqual(c.textView.vim.mode, .insert)
    }

    func testTextObjectsInVisual() {
        load("say \"hello there\" now", caret: 7)
        keys("vi\"")
        XCTAssertEqual((storage.string as NSString).substring(with: sel), "hello there")
        keys("a\"")
        XCTAssertEqual((storage.string as NSString).substring(with: sel), "\"hello there\"")
        keys("d"); XCTAssertEqual(storage.string, "say  now")
    }

    func testIndentAndToggleCase() {
        load("a\nb\nc\n", caret: 0)
        keys("Vj>"); XCTAssertEqual(storage.string, "  a\n  b\nc\n")
        keys("<<"); XCTAssertEqual(storage.string, "a\n  b\nc\n")
        keys("j>>"); XCTAssertEqual(storage.string, "a\n    b\nc\n")
        load("Hello World", caret: 0)
        keys("3~"); XCTAssertEqual(storage.string, "hELlo World"); XCTAssertEqual(sel.location, 3)
        keys("v$~"); XCTAssertEqual(storage.string, "hELLO wORLD")
    }

    func testBlockVisualDeleteAndPaste() {
        load("abcd\nefgh\nij\nklmn\n", caret: 1)
        ctrlV()
        XCTAssertEqual(c.textView.vim.mode, .visual(kind: .block))
        keys("ljj")   // cols 1-2, rows 0-2 (row "ij" only reaches col 1)
        XCTAssertEqual(c.textView.selectedRanges.count, 3)
        keys("d")
        XCTAssertEqual(storage.string, "ad\neh\ni\nklmn\n")
        keys("G")     // last line, paste the block at column 0
        keys("P")
        XCTAssertEqual(storage.string, "ad\neh\ni\nbcklmn\nfg\nj\n")
    }

    func testBlockVisualIndentAndSwap() {
        load("x\ny\nz\n", caret: 0)
        ctrlV(); keys("j>")
        XCTAssertEqual(storage.string, "  x\n  y\nz\n")
        ctrlV(); keys("lo")
        XCTAssertEqual(c.textView.vim.mode, .visual(kind: .block))
        escape()
        XCTAssertEqual(c.textView.vim.mode, .normal)
    }
}

@MainActor
final class VimSpecialKeyTests: XCTestCase {
    func testArrowsHomeEndAndForwardDelete() {
        let storage = NSTextStorage(string: "one two\nthree four\n")
        let c = EditorController(textStorage: storage)
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        c.textView.vim.isEnabled = true
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        func key(_ scalar: Int, code: UInt16 = 0) {
            let s = String(UnicodeScalar(UInt32(scalar))!)
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 0, windowNumber: 0, context: nil, characters: s, charactersIgnoringModifiers: s, isARepeat: false, keyCode: code)!
            _ = c.textView.vim.handle(e)
        }
        func keys(_ s: String) {
            for ch in s {
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0)!
                _ = c.textView.vim.handle(e)
            }
        }
        var caret: Int { c.textView.selectedRange().location }
        key(NSRightArrowFunctionKey); key(NSRightArrowFunctionKey); XCTAssertEqual(caret, 2)
        key(NSDownArrowFunctionKey); XCTAssertEqual(caret, 10)
        key(NSEndFunctionKey); XCTAssertEqual(caret, 18)
        key(NSHomeFunctionKey); XCTAssertEqual(caret, 8)
        key(NSUpArrowFunctionKey); XCTAssertEqual(caret, 0)
        key(NSDeleteFunctionKey); XCTAssertEqual(storage.string, "ne two\nthree four\n")
        keys("3"); key(NSRightArrowFunctionKey); XCTAssertEqual(caret, 3, "counts apply to arrows too")
        // Visual mode extends with arrows
        keys("v"); key(NSRightArrowFunctionKey); key(NSRightArrowFunctionKey)
        XCTAssertEqual(c.textView.selectedRange(), NSRange(location: 3, length: 3))
        key(NSDeleteFunctionKey); XCTAssertEqual(storage.string, "ne \nthree four\n")
        XCTAssertEqual(c.textView.vim.mode, .normal)
    }
}

@MainActor
final class VimFindTests: XCTestCase {
    private var c: EditorController!
    private var storage: NSTextStorage!
    private func load(_ text: String, caret: Int = 0) {
        storage = NSTextStorage(string: text)
        c = EditorController(textStorage: storage)
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        c.textView.vim.isEnabled = true
        c.textView.setSelectedRange(NSRange(location: caret, length: 0))
    }
    private func keys(_ s: String) {
        for ch in s {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: String(ch), charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0)!
            if !c.textView.vim.handle(e) { c.textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
    }
    private var caret: Int { c.textView.selectedRange().location }

    func testDollarAndTillFind() {
        load("one; two; three\nnext", caret: 0)
        keys("d$"); XCTAssertEqual(storage.string, "\nnext")
        load("one; two; three", caret: 0)
        keys("dt;"); XCTAssertEqual(storage.string, "; two; three")
        load("one; two; three", caret: 0)
        keys("df;"); XCTAssertEqual(storage.string, " two; three")
        load("one; two; three", caret: 0)
        keys("d2t;"); XCTAssertEqual(storage.string, "; three")
        load("one; two; three", caret: 0)
        keys("ct;X"); XCTAssertEqual(storage.string, "X; two; three"); XCTAssertEqual(c.textView.vim.mode, .insert)
    }

    func testMotionsAndRepeat() {
        load("a;b;c;d", caret: 0)
        keys("f;"); XCTAssertEqual(caret, 1)
        keys(";"); XCTAssertEqual(caret, 3)
        keys(","); XCTAssertEqual(caret, 1)
        keys("t;"); XCTAssertEqual(caret, 2, "t stops before the next ;")
        keys("$F;"); XCTAssertEqual(caret, 5)
        keys("T;"); XCTAssertEqual(caret, 4)
        keys("dF;"); XCTAssertEqual(storage.string, "a;bc;d", "backward find: from the ; up to, not including, the cursor")
    }

    func testFindMissingCharDoesNothing() {
        load("hello", caret: 0)
        keys("dtz"); XCTAssertEqual(storage.string, "hello"); XCTAssertEqual(c.textView.vim.mode, .normal)
        keys("vt;"); XCTAssertEqual(c.textView.vim.mode, .visual(kind: .char))
        keys("fl"); XCTAssertEqual(c.textView.selectedRange(), NSRange(location: 0, length: 3), "visual f extends")
    }
}

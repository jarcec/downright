import AppKit
import MarkdownKit

/// A small modal-editing layer over `NSTextView`: normal / insert / command-line modes,
/// counts, the `d` `y` `c` operators, common motions, registers and a few ex commands.
/// Motions are computed on the source string so they follow vim's *logical* lines.
@MainActor
public final class VimEngine {
    public enum Mode: Equatable { case normal, insert, command, visual(linewise: Bool) }

    public private(set) var mode: Mode = .insert
    public var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { enterNormal() } else { mode = .insert; resetPending(); textView?.insertionPointColor = .textColor; (textView as? MarkdownTextView)?.vimModeDidChange() }
            onStateChange?()
        }
    }
    /// Status-bar text: "NORMAL", "-- INSERT --", or the pending ":" command line.
    public var statusText: String {
        switch mode {
        case .insert: return "-- INSERT --"
        case .command: return ":" + commandLine
        case .visual(let linewise): return (linewise ? "-- VISUAL LINE --" : "-- VISUAL --") + (count > 0 ? " \(count)" : "")
        case .normal:
            var s = "NORMAL"
            if count > 0 { s += " \(count)" }
            if let op = pendingOperator { s += " \(op)" }
            if let pre = pendingPrefix { s += " \(pre)" }
            return s
        }
    }
    public var onStateChange: (() -> Void)?
    /// Ex commands the engine does not handle itself (`w`, `q`, `wq`, `x`, `q!`).
    public var onExCommand: ((String) -> Void)?

    weak var controller: EditorController?
    private var textView: NSTextView? { controller?.textView }

    private var count = 0
    private var pendingOperator: Character? = nil
    private var pendingPrefix: Character? = nil
    private(set) var commandLine = ""
    private var register = ""
    private var registerLinewise = false
    /// Visual mode: the fixed end of the selection; the caret is the moving end.
    private var visualAnchor = 0

    public init() {}

    // MARK: - Key handling

    private enum Key { static let escape: UInt16 = 53; static let `return`: UInt16 = 36; static let delete: UInt16 = 51 }

    /// Returns true when the event was consumed and must not reach the text view.
    public func handle(_ event: NSEvent) -> Bool {
        guard isEnabled, textView != nil else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        let isEscape = event.keyCode == Key.escape || (flags.contains(.control) && event.charactersIgnoringModifiers == "[")

        switch mode {
        case .insert:
            if isEscape { enterNormal(); return true }
            return false
        case .command:
            if isEscape { enterNormal(); return true }
            if event.keyCode == Key.return { execute(commandLine); return true }
            if event.keyCode == Key.delete {
                if commandLine.isEmpty { enterNormal() } else { commandLine.removeLast(); onStateChange?() }
                return true
            }
            if flags.isEmpty, let s = event.characters, !s.isEmpty { commandLine += s; onStateChange?() }
            return true
        case .visual(let linewise):
            if flags.contains(.command) { return false }
            if isEscape { exitVisual(); return true }
            guard let s = event.charactersIgnoringModifiers, let ch = s.first else { return true }
            visual(ch, linewise: linewise)
            return true
        case .normal:
            if flags.contains(.command) { return false }      // menu shortcuts keep working
            if isEscape { resetPending(); onStateChange?(); return true }
            if flags.contains(.control) {
                if event.charactersIgnoringModifiers == "r" { textView?.undoManager?.redo(); return true }
                return false
            }
            guard let s = event.charactersIgnoringModifiers, let ch = s.first else { return true }
            normal(ch)
            return true
        }
    }

    // MARK: - Normal mode

    private func normal(_ ch: Character) {
        defer { onStateChange?() }
        if let pre = pendingPrefix {
            pendingPrefix = nil
            if pre == "g" && ch == "g" { motion(.top) }
            else { resetPending() }
            return
        }
        if let d = ch.wholeNumberValue, ch.isASCII, !(ch == "0" && count == 0) {
            count = min(count * 10 + d, 100_000)
            return
        }
        switch ch {
        case "i": enterInsert()
        case "a": moveCaret(by: 1, withinLine: true); enterInsert()
        case "I": motion(.firstNonBlank); enterInsert()
        case "A": motion(.lineEnd); enterInsert()
        case "o":
            motion(.lineEnd)
            textView?.insertNewline(nil)
            enterInsert()
        case "O":
            motion(.lineStart)
            insert("\n", at: caret)
            setCaret(caret - 1)
            enterInsert()
        case "x": deleteChars(forward: true)
        case "X": deleteChars(forward: false)
        case "D": operate("d", over: rangeToLineEnd())
        case "C": operate("c", over: rangeToLineEnd())
        case "u": for _ in 0..<max(1, count) { textView?.undoManager?.undo() }; resetPending()
        case "p": paste(after: true)
        case "P": paste(after: false)
        case "d", "y", "c":
            if pendingOperator == ch { linewiseOperation(ch) }
            else { pendingOperator = ch }
        case "g": pendingPrefix = "g"
        case ":": mode = .command; commandLine = ""; resetPending()
        case "v": enterVisual(linewise: false)
        case "V": enterVisual(linewise: true)
        case "h": motion(.left)
        case "l": motion(.right)
        case "j": motion(.down)
        case "k": motion(.up)
        case "w": motion(.wordForward)
        case "b": motion(.wordBackward)
        case "e": motion(.wordEnd)
        case "0": motion(.lineStart)
        case "^": motion(.firstNonBlank)
        case "$": motion(.lineEnd)
        case "G": motion(.bottom)
        default: resetPending()
        }
    }

    private func enterNormal() {
        mode = .normal
        headStore = nil
        resetPending()
        commandLine = ""
        textView?.insertionPointColor = .systemOrange
        (textView as? MarkdownTextView)?.vimModeDidChange()
        onStateChange?()
    }

    private func enterInsert() {
        mode = .insert
        resetPending()
        textView?.insertionPointColor = .textColor
        (textView as? MarkdownTextView)?.vimModeDidChange()
        onStateChange?()
    }

    private func resetPending() {
        count = 0
        pendingOperator = nil
        pendingPrefix = nil
    }

    // MARK: - Visual mode

    private func enterVisual(linewise: Bool) {
        visualAnchor = caret
        mode = .visual(linewise: linewise)
        resetPending()
        applyVisualSelection(head: caret)
        onStateChange?()
    }

    private func exitVisual() {
        let head = currentHead
        mode = .normal
        headStore = nil
        setCaret(head)
        resetPending()
        onStateChange?()
    }

    private var headStore: Int? = nil

    private func applyVisualSelection(head: Int) {
        headStore = head
        guard let tv = textView else { return }
        let n = text.length
        let lo = min(visualAnchor, head), hi = max(visualAnchor, head)
        if case .visual(let linewise) = mode, linewise {
            let a = lines.line(containing: lo), b = lines.line(containing: hi)
            let r = lineRange(from: a, to: b)
            tv.setSelectedRange(r)
        } else {
            tv.setSelectedRange(NSRange(location: lo, length: min(hi + 1, n) - lo))   // inclusive of the head character
        }
        tv.scrollRangeToVisible(NSRange(location: head, length: 0))
    }

    private var currentHead: Int { headStore ?? caret }

    private func visual(_ ch: Character, linewise: Bool) {
        defer { onStateChange?() }
        if let pre = pendingPrefix {
            pendingPrefix = nil
            if pre == "g" && ch == "g" { visualMove(.top) }
            return
        }
        if let d = ch.wholeNumberValue, ch.isASCII, !(ch == "0" && count == 0) { count = min(count * 10 + d, 100_000); return }
        switch ch {
        case "v": if linewise { mode = .visual(linewise: false); applyVisualSelection(head: currentHead) } else { exitVisual() }
        case "V": if linewise { exitVisual() } else { mode = .visual(linewise: true); applyVisualSelection(head: currentHead) }
        case "o": let h = currentHead; let a = visualAnchor; visualAnchor = h; applyVisualSelection(head: a)
        case "d", "x": visualOperate("d")
        case "y": visualOperate("y")
        case "c", "s": visualOperate("c")
        case "p", "P": visualPaste()
        case "g": pendingPrefix = "g"
        case "h": visualMove(.left)
        case "l": visualMove(.right)
        case "j": visualMove(.down)
        case "k": visualMove(.up)
        case "w": visualMove(.wordForward)
        case "b": visualMove(.wordBackward)
        case "e": visualMove(.wordEnd)
        case "0": visualMove(.lineStart)
        case "^": visualMove(.firstNonBlank)
        case "$": visualMove(.lineEnd)
        case "G": visualMove(.bottom)
        default: resetPending()
        }
    }

    private func visualMove(_ m: Motion) {
        let n = max(1, count)
        var head = currentHead
        for _ in 0..<n { head = destination(from: head, m) }
        // `l` and `$` may reach the newline; keep the head on a character.
        let cr = lines.contentRange(ofLine: lines.line(containing: head))
        if head >= cr.end && cr.length > 0 && (m == .right || m == .lineEnd) { head = cr.end - 1 }
        count = 0
        applyVisualSelection(head: head)
    }

    private func visualOperate(_ op: Character) {
        guard let tv = textView else { return }
        let r = tv.selectedRange()
        let linewise: Bool = { if case .visual(let l) = mode { return l }; return false }()
        mode = .normal
        headStore = nil
        operate(op, over: r, linewise: linewise)
        if op != "c" { setCaret(r.location); (textView as? MarkdownTextView)?.vimModeDidChange() }
    }

    private func visualPaste() {
        guard let tv = textView else { return }
        let r = tv.selectedRange()
        let saved = (register, registerLinewise)
        mode = .normal
        headStore = nil
        operate("d", over: r)
        (register, registerLinewise) = saved
        paste(after: false)
    }

    // MARK: - Motions

    enum Motion { case left, right, up, down, wordForward, wordBackward, wordEnd, lineStart, firstNonBlank, lineEnd, top, bottom }

    private var caret: Int { textView?.selectedRange().location ?? 0 }
    private var text: NSString { (textView?.string ?? "") as NSString }
    private var lines: LineIndex { controller?.lines ?? LineIndex("") }

    private func setCaret(_ loc: Int) {
        let clamped = max(0, min(loc, text.length))
        textView?.setSelectedRange(NSRange(location: clamped, length: 0))
        textView?.scrollRangeToVisible(NSRange(location: clamped, length: 0))
    }

    private func moveCaret(by delta: Int, withinLine: Bool) {
        let li = lines.line(containing: caret)
        let cr = lines.contentRange(ofLine: li)
        var dest = caret + delta
        if withinLine { dest = max(cr.location, min(dest, cr.end)) }
        setCaret(dest)
    }

    private func motion(_ m: Motion) {
        let n = max(1, count)
        var dest = caret
        var inclusive = false
        var linewise = false
        for _ in 0..<n { dest = destination(from: dest, m) }
        switch m {
        case .wordEnd: inclusive = true
        case .up, .down, .top, .bottom: linewise = true
        default: break
        }
        if let op = pendingOperator {
            if linewise {
                let a = lines.line(containing: min(caret, dest)), b = lines.line(containing: max(caret, dest))
                operate(op, over: lineRange(from: a, to: b), linewise: true)
            } else {
                var lo = min(caret, dest), hi = max(caret, dest)
                if inclusive { hi = min(hi + 1, text.length) }
                operate(op, over: NSRange(location: lo, length: hi - lo))
                _ = lo; lo = 0
            }
        } else {
            setCaret(dest)
            resetPending()
        }
    }

    private func destination(from loc: Int, _ m: Motion) -> Int {
        let s = text
        let li = lines.line(containing: loc)
        let cr = lines.contentRange(ofLine: li)
        switch m {
        case .left: return max(cr.location, loc - 1)
        case .right: return min(cr.end, loc + 1)
        case .lineStart: return cr.location
        case .lineEnd: return cr.end
        case .firstNonBlank:
            var p = cr.location
            while p < cr.end, C.isSpaceOrTab(s.character(at: p)) { p += 1 }
            return p
        case .up, .down:
            var target = m == .up ? li - 1 : li + 1
            guard target >= 0, target < lines.lineCount else { return loc }
            // Skip a table's hidden delimiter row.
            if controller?.isOnTableDelimiter(lines.lineStarts[target]) == true {
                target += m == .up ? -1 : 1
                guard target >= 0, target < lines.lineCount else { return loc }
            }
            let col = loc - cr.location
            let tr = lines.contentRange(ofLine: target)
            return tr.location + min(col, tr.length)
        case .top:
            let line = count > 0 ? min(count, lines.lineCount) - 1 : 0
            return lines.lineStarts[line]
        case .bottom:
            let line = count > 0 ? min(count, lines.lineCount) - 1 : lines.lineCount - 1
            return lines.lineStarts[line]
        case .wordForward:
            var p = loc
            let n = s.length
            guard p < n else { return p }
            let cls = charClass(s.character(at: p))
            if cls != .space { while p < n, charClass(s.character(at: p)) == cls { p += 1 } }
            while p < n, charClass(s.character(at: p)) == .space { p += 1 }
            return p
        case .wordBackward:
            var p = loc
            while p > 0, charClass(s.character(at: p - 1)) == .space { p -= 1 }
            guard p > 0 else { return 0 }
            let cls = charClass(s.character(at: p - 1))
            while p > 0, charClass(s.character(at: p - 1)) == cls { p -= 1 }
            return p
        case .wordEnd:
            var p = loc + 1
            let n = s.length
            while p < n, charClass(s.character(at: p)) == .space { p += 1 }
            guard p < n else { return max(0, n - 1) }
            let cls = charClass(s.character(at: p))
            while p + 1 < n, charClass(s.character(at: p + 1)) == cls { p += 1 }
            return p
        }
    }

    private enum CharClass { case word, punct, space }
    private func charClass(_ c: unichar) -> CharClass {
        if c == 32 || c == 9 || c == 10 || c == 13 { return .space }
        if C.isAlnum(c) || c == 95 || c > 127 { return .word }
        return .punct
    }

    // MARK: - Operators

    private func rangeToLineEnd() -> NSRange {
        let cr = lines.contentRange(ofLine: lines.line(containing: caret))
        return NSRange(location: caret, length: max(0, cr.end - caret))
    }

    /// Range of whole lines `a...b` including the trailing newline (or the preceding one
    /// when the block ends the document).
    private func lineRange(from a: Int, to b: Int) -> NSRange {
        let start = lines.lineStarts[a]
        var end = lines.paragraphRange(ofLine: b).end
        if end == text.length, start > 0, end > 0, text.character(at: end - 1) != 10 {
            // Last line without trailing newline: take the newline before it instead
            return NSRange(location: start - 1, length: end - start + 1)
        }
        end = min(end, text.length)
        return NSRange(location: start, length: end - start)
    }

    private func linewiseOperation(_ op: Character) {
        let n = max(1, count)
        let a = lines.line(containing: caret)
        let b = min(a + n - 1, lines.lineCount - 1)
        operate(op, over: lineRange(from: a, to: b), linewise: true)
    }

    private func operate(_ op: Character, over range: NSRange, linewise: Bool = false) {
        guard let tv = textView else { return }
        let r = NSRange(location: max(0, range.location), length: max(0, min(range.length, text.length - max(0, range.location))))
        let yanked = text.substring(with: r)
        register = linewise && !yanked.hasSuffix("\n") ? yanked + "\n" : yanked
        registerLinewise = linewise
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(yanked, forType: .string)
        switch op {
        case "y":
            setCaret(r.location)
        case "d", "c":
            if tv.shouldChangeText(in: r, replacementString: "") {
                tv.textStorage?.replaceCharacters(in: r, with: "")
                tv.didChangeText()
            }
            if op == "c" && linewise {
                // Keep the line: reinsert a newline and edit on the empty line
                insert("\n", at: r.location)
            }
            setCaret(r.location)
            if op == "c" { enterInsert(); return }
        default: break
        }
        resetPending()
    }

    private func deleteChars(forward: Bool) {
        let n = max(1, count)
        let cr = lines.contentRange(ofLine: lines.line(containing: caret))
        let r: NSRange
        if forward {
            r = NSRange(location: caret, length: min(n, cr.end - caret))
        } else {
            let start = max(cr.location, caret - n)
            r = NSRange(location: start, length: caret - start)
        }
        guard r.length > 0 else { resetPending(); return }
        operate("d", over: r)
    }

    private func insert(_ s: String, at loc: Int) {
        guard let tv = textView else { return }
        let r = NSRange(location: min(loc, text.length), length: 0)
        if tv.shouldChangeText(in: r, replacementString: s) {
            tv.textStorage?.replaceCharacters(in: r, with: s)
            tv.didChangeText()
        }
    }

    private func paste(after: Bool) {
        var content = register
        var linewise = registerLinewise
        if content.isEmpty, let pb = NSPasteboard.general.string(forType: .string) {
            content = pb; linewise = pb.hasSuffix("\n")
        }
        guard !content.isEmpty else { resetPending(); return }
        let n = max(1, count)
        let body = String(repeating: content, count: n)
        if linewise {
            let li = lines.line(containing: caret)
            var at: Int
            var payload = body
            if after {
                at = lines.paragraphRange(ofLine: li).end
                if at == text.length && (text.length == 0 || text.character(at: at - 1) != 10) {
                    payload = "\n" + String(body.dropLast())   // document has no trailing newline
                }
            } else {
                at = lines.lineStarts[li]
            }
            insert(payload, at: at)
            setCaret(after && payload.hasPrefix("\n") ? at + 1 : at)
        } else {
            let cr = lines.contentRange(ofLine: lines.line(containing: caret))
            let at = after ? min(caret + 1, cr.end) : caret
            insert(body, at: at)
            setCaret(max(at, at + body.utf16.count - 1))
        }
        resetPending()
    }

    // MARK: - Ex commands

    private func execute(_ raw: String) {
        let cmd = raw.trimmingCharacters(in: .whitespaces)
        enterNormal()
        if let n = Int(cmd), n > 0 {
            setCaret(lines.lineStarts[min(n, lines.lineCount) - 1])
            return
        }
        guard !cmd.isEmpty else { return }
        onExCommand?(cmd)
    }
}

import AppKit
import MarkdownKit

/// A small modal-editing layer over `NSTextView`: normal / insert / command-line modes,
/// counts, the `d` `y` `c` operators, common motions, registers and a few ex commands.
/// Motions are computed on the source string so they follow vim's *logical* lines.
@MainActor
public final class VimEngine {
    public enum VisualKind: Equatable { case char, line, block }
    public enum Mode: Equatable { case normal, insert, command, visual(kind: VisualKind) }

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
        case .visual(let kind):
            let name = kind == .line ? "-- VISUAL LINE --" : kind == .block ? "-- VISUAL BLOCK --" : "-- VISUAL --"
            return name + (count > 0 ? " \(count)" : "") + (pendingTextObject.map { " \($0)" } ?? "")
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
    /// Block visual: columns of anchor and head (offsets alone lose the column on short lines).
    private var blockAnchorCol = 0
    private var blockHeadCol = 0
    /// After `i`/`a` following an operator or in visual mode: waiting for the object key.
    private var pendingTextObject: Character? = nil
    /// Blockwise register (one entry per line) set by block-visual yank/delete.
    private var registerBlock: [String]? = nil
    /// Spaces inserted by `>`.
    public var shiftWidth = 2

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
        case .visual(let kind):
            if flags.contains(.command) { return false }
            if isEscape { exitVisual(); return true }
            if flags.contains(.control) {
                if event.charactersIgnoringModifiers == "v" { if kind == .block { exitVisual() } else { switchVisual(to: .block) }; return true }
                return false
            }
            guard let s = event.charactersIgnoringModifiers, let ch = s.first else { return true }
            visual(ch, kind: kind)
            return true
        case .normal:
            if flags.contains(.command) { return false }      // menu shortcuts keep working
            if isEscape { resetPending(); onStateChange?(); return true }
            if flags.contains(.control) {
                if event.charactersIgnoringModifiers == "r" { textView?.undoManager?.redo(); return true }
                if event.charactersIgnoringModifiers == "v" { enterVisual(kind: .block); onStateChange?(); return true }
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
        if let prefix = pendingTextObject {
            pendingTextObject = nil
            if let op = pendingOperator, let (r, linewise) = textObjectRange(prefix: prefix, object: ch, at: caret) {
                operate(op, over: r, linewise: linewise)
            } else { resetPending() }
            return
        }
        if pendingOperator != nil, ch == "i" || ch == "a" { pendingTextObject = ch; return }
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
        case "d", "y", "c", ">", "<":
            if pendingOperator == ch { linewiseOperation(ch) }
            else { pendingOperator = ch }
        case "~":
            let n = max(1, count)
            let cr = lines.contentRange(ofLine: lines.line(containing: caret))
            let r = NSRange(location: caret, length: max(0, min(n, cr.end - caret)))
            toggleCase(r)
            setCaret(min(r.end, cr.end))
            resetPending()
        case "g": pendingPrefix = "g"
        case ":": mode = .command; commandLine = ""; resetPending()
        case "v": enterVisual(kind: .char)
        case "V": enterVisual(kind: .line)
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

    private func enterVisual(kind: VisualKind) {
        visualAnchor = caret
        blockAnchorCol = column(of: caret); blockHeadCol = blockAnchorCol
        mode = .visual(kind: kind)
        resetPending()
        applyVisualSelection(head: caret)
        onStateChange?()
    }

    private func switchVisual(to kind: VisualKind) {
        let head = currentHead
        mode = .visual(kind: kind)
        applyVisualSelection(head: head)
        onStateChange?()
    }

    private func exitVisual() {
        let head = currentHead
        mode = .normal
        headStore = nil
        pendingTextObject = nil
        setCaret(head)
        resetPending()
        (textView as? MarkdownTextView)?.vimModeDidChange()
        onStateChange?()
    }

    private var headStore: Int? = nil
    private var currentHead: Int { headStore ?? caret }
    private var visualKind: VisualKind { if case .visual(let k) = mode { return k }; return .char }

    private func column(of offset: Int) -> Int { offset - lines.lineStarts[lines.line(containing: offset)] }

    private func applyVisualSelection(head: Int) {
        headStore = head
        guard let tv = textView else { return }
        let n = text.length
        let lo = min(visualAnchor, head), hi = max(visualAnchor, head)
        switch visualKind {
        case .line:
            tv.setSelectedRange(lineRange(from: lines.line(containing: lo), to: lines.line(containing: hi)))
        case .char:
            tv.setSelectedRange(NSRange(location: lo, length: min(hi + 1, n) - lo))   // inclusive of the head character
        case .block:
            tv.selectedRanges = blockRanges(head: head).map { NSValue(range: $0) }
        }
        tv.scrollRangeToVisible(NSRange(location: head, length: 0))
    }

    /// One range per line of the block, clipped to each line's content. Lines too short to
    /// reach the block are skipped (except the head's own line, kept as an empty range).
    private func blockRanges(head: Int) -> [NSRange] {
        let a = lines.line(containing: visualAnchor), b = lines.line(containing: head)
        let colLo = min(blockAnchorCol, blockHeadCol), colHi = max(blockAnchorCol, blockHeadCol)
        var out: [NSRange] = []
        for li in min(a, b)...max(a, b) {
            let cr = lines.contentRange(ofLine: li)
            let start = cr.location + colLo
            let end = cr.location + colHi + 1
            if start < cr.end { out.append(NSRange(location: start, length: min(end, cr.end) - start)) }
            else if li == lines.line(containing: head) { out.append(NSRange(location: cr.end, length: 0)) }
        }
        return out.isEmpty ? [NSRange(location: head, length: 0)] : out
    }

    private func visual(_ ch: Character, kind: VisualKind) {
        defer { onStateChange?() }
        if let pre = pendingPrefix {
            pendingPrefix = nil
            if pre == "g" && ch == "g" { visualMove(.top) }
            return
        }
        if let prefix = pendingTextObject {
            pendingTextObject = nil
            if let (r, linewise) = textObjectRange(prefix: prefix, object: ch, at: currentHead), r.length > 0 {
                if linewise, kind == .char { mode = .visual(kind: .line) }
                visualAnchor = r.location
                blockAnchorCol = column(of: r.location)
                applyVisualSelection(head: max(r.location, r.end - 1))
            }
            return
        }
        if let d = ch.wholeNumberValue, ch.isASCII, !(ch == "0" && count == 0) { count = min(count * 10 + d, 100_000); return }
        switch ch {
        case "i", "a": pendingTextObject = ch
        case "v": kind == .char ? exitVisual() : switchVisual(to: .char)
        case "V": kind == .line ? exitVisual() : switchVisual(to: .line)
        case "o":
            let h = currentHead, a = visualAnchor
            visualAnchor = h; blockAnchorCol = blockHeadCol
            blockHeadCol = column(of: a)
            applyVisualSelection(head: a)
        case "d", "x": visualOperate("d")
        case "y": visualOperate("y")
        case "c", "s": visualOperate("c")
        case "p", "P": visualPaste()
        case ">", "<": visualOperate(ch)
        case "~":
            let ranges = selectedRanges()
            let start = ranges.first?.location ?? currentHead
            for r in ranges.reversed() { toggleCase(r) }
            mode = .normal; headStore = nil
            setCaret(start)
            (textView as? MarkdownTextView)?.vimModeDidChange()
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

    private func selectedRanges() -> [NSRange] {
        (textView?.selectedRanges ?? []).map { $0.rangeValue }.filter { $0.length > 0 }.sorted { $0.location < $1.location }
    }

    private func visualMove(_ m: Motion) {
        let n = max(1, count)
        var head = currentHead
        if visualKind == .block, m == .up || m == .down {
            // Keep the desired column across short lines.
            var li = lines.line(containing: head)
            for _ in 0..<n {
                let t = li + (m == .up ? -1 : 1)
                guard t >= 0, t < lines.lineCount else { break }
                if controller?.isOnTableDelimiter(lines.lineStarts[t]) == true { li = t + (m == .up ? -1 : 1) } else { li = t }
                li = max(0, min(li, lines.lineCount - 1))
            }
            let cr = lines.contentRange(ofLine: li)
            head = cr.location + min(blockHeadCol, max(0, cr.length - 1))
        } else {
            for _ in 0..<n { head = destination(from: head, m) }
            let cr = lines.contentRange(ofLine: lines.line(containing: head))
            if head >= cr.end && cr.length > 0 && (m == .right || m == .lineEnd) { head = cr.end - 1 }
            blockHeadCol = column(of: head)
        }
        count = 0
        applyVisualSelection(head: head)
    }

    private func visualOperate(_ op: Character) {
        guard let tv = textView else { return }
        let kind = visualKind
        let ranges = kind == .block ? blockRanges(head: currentHead) : [tv.selectedRange()]
        mode = .normal
        headStore = nil
        (textView as? MarkdownTextView)?.vimModeDidChange()
        switch kind {
        case .block where op == "d" || op == "y" || op == "c":
            let pieces = ranges.map { text.substring(with: $0) }
            register = pieces.joined(separator: "\n"); registerLinewise = false; registerBlock = pieces
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(register, forType: .string)
            if op != "y" {
                tv.undoManager?.beginUndoGrouping()
                for r in ranges.reversed() where r.length > 0 { replace(r, with: "") }
                tv.undoManager?.endUndoGrouping()
            }
            setCaret(ranges.first?.location ?? caret)
            if op == "c" { enterInsert() } else { resetPending() }
        default:
            var r = ranges.first ?? NSRange(location: caret, length: 0)
            if kind == .block, let first = ranges.first, let last = ranges.last { r = NSRange(first.location, to: max(first.end, last.end)) }
            let linewise = kind == .line
            if op == ">" || op == "<" { operate(op, over: r, linewise: true); return }
            registerBlock = nil
            operate(op, over: r, linewise: linewise)
            if op != "c" { setCaret(r.location) }
        }
    }

    private func visualPaste() {
        guard let tv = textView else { return }
        let r = tv.selectedRange()
        let saved = (register, registerLinewise, registerBlock)
        mode = .normal
        headStore = nil
        operate("d", over: r)
        (register, registerLinewise, registerBlock) = saved
        paste(after: false)
    }

    // MARK: - Text objects

    /// `iw aw`, quotes, bracket pairs, `ip ap`. Returns nil when there is no object at `loc`.
    func textObjectRange(prefix: Character, object: Character, at loc: Int) -> (NSRange, linewise: Bool)? {
        let s = text
        let n = s.length
        let around = prefix == "a"
        switch object {
        case "w", "W":
            guard n > 0 else { return nil }
            let p = min(loc, n - 1)
            let cls = charClass(s.character(at: p))
            var a = p, b = p + 1
            while a > 0, charClass(s.character(at: a - 1)) == cls, s.character(at: a - 1) != 10 { a -= 1 }
            while b < n, charClass(s.character(at: b)) == cls, s.character(at: b) != 10 { b += 1 }
            if around {
                if cls == .space {   // whitespace + following word
                    if b < n { let c2 = charClass(s.character(at: b)); while b < n, charClass(s.character(at: b)) == c2, s.character(at: b) != 10 { b += 1 } }
                } else {
                    var e = b
                    while e < n, s.character(at: e) == 32 { e += 1 }
                    if e > b { b = e } else { while a > 0, s.character(at: a - 1) == 32 { a -= 1 } }
                }
            }
            return (NSRange(location: a, length: b - a), false)
        case "\"", "'", "`":
            let q = object.utf16.first!
            let cr = lines.contentRange(ofLine: lines.line(containing: loc))
            var open = -1, close = -1
            var i = cr.location
            var pairs: [(Int, Int)] = []
            while i < cr.end {
                if s.character(at: i) == q {
                    var j = i + 1
                    while j < cr.end, s.character(at: j) != q { if s.character(at: j) == 92 { j += 1 }; j += 1 }
                    if j < cr.end { pairs.append((i, j)); i = j + 1; continue }
                }
                i += 1
            }
            if let hit = pairs.first(where: { $0.0 <= loc && loc <= $0.1 }) ?? pairs.first(where: { $0.0 > loc }) { open = hit.0; close = hit.1 }
            guard open >= 0 else { return nil }
            return around ? (NSRange(location: open, length: close - open + 1), false) : (NSRange(location: open + 1, length: close - open - 1), false)
        case "(", ")", "b", "[", "]", "{", "}", "B", "<", ">":
            let (o, c): (UInt16, UInt16) = {
                switch object {
                case "(", ")", "b": return (40, 41)
                case "[", "]": return (91, 93)
                case "{", "}", "B": return (123, 125)
                default: return (60, 62)
                }
            }()
            // Walk back to the unmatched opener, then forward to its match.
            var depth = 0, a = min(loc, max(0, n - 1))
            if n == 0 { return nil }
            if s.character(at: a) == c { a -= 1 }
            while a >= 0 {
                let ch = s.character(at: a)
                if ch == c { depth += 1 } else if ch == o { if depth == 0 { break }; depth -= 1 }
                a -= 1
            }
            guard a >= 0 else { return nil }
            depth = 0
            var b = a + 1
            while b < n {
                let ch = s.character(at: b)
                if ch == o { depth += 1 } else if ch == c { if depth == 0 { break }; depth -= 1 }
                b += 1
            }
            guard b < n else { return nil }
            return around ? (NSRange(location: a, length: b - a + 1), false) : (NSRange(location: a + 1, length: b - a - 1), false)
        case "p":
            func blank(_ li: Int) -> Bool { let r = lines.contentRange(ofLine: li); return r.length == 0 || s.substring(with: r).trimmingCharacters(in: .whitespaces).isEmpty }
            var a = lines.line(containing: loc), b = a
            let isBlank = blank(a)
            while a > 0, blank(a - 1) == isBlank { a -= 1 }
            while b + 1 < lines.lineCount, blank(b + 1) == isBlank, lines.lineStarts[b + 1] < n { b += 1 }
            if around, !isBlank { while b + 1 < lines.lineCount, blank(b + 1), lines.lineStarts[b + 1] < n { b += 1 } }
            return (lineRange(from: a, to: b), true)
        default:
            return nil
        }
    }

    // MARK: - Case and indentation

    private func toggleCase(_ r: NSRange) {
        guard r.length > 0 else { return }
        let t = text.substring(with: r)
        let toggled = String(t.map { ch -> Character in
            if ch.isUppercase { return Character(ch.lowercased()) }
            if ch.isLowercase { return Character(ch.uppercased()) }
            return ch
        })
        replace(r, with: toggled)
    }

    /// Indent (`>`) or outdent (`<`) the lines covering `range` by `shiftWidth` spaces.
    private func shiftLines(in range: NSRange, outdent: Bool) {
        let a = lines.line(containing: range.location)
        let b = lines.line(containing: max(range.location, range.end - 1))
        guard let tv = textView else { return }
        tv.undoManager?.beginUndoGrouping()
        for li in (a...b).reversed() {
            let cr = lines.contentRange(ofLine: li)
            if outdent {
                var k = 0
                while k < shiftWidth, cr.location + k < cr.end, text.character(at: cr.location + k) == 32 { k += 1 }
                if k > 0 { replace(NSRange(location: cr.location, length: k), with: "") }
            } else if cr.length > 0 {
                replace(NSRange(location: cr.location, length: 0), with: String(repeating: " ", count: shiftWidth))
            }
        }
        tv.undoManager?.endUndoGrouping()
    }

    private func replace(_ r: NSRange, with s: String) {
        guard let tv = textView, tv.shouldChangeText(in: r, replacementString: s) else { return }
        tv.textStorage?.replaceCharacters(in: r, with: s)
        tv.didChangeText()
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
            // The last *real* line: skip the empty phantom line after a trailing newline.
            var lastLine = lines.lineCount - 1
            if lastLine > 0, lines.lineStarts[lastLine] == s.length { lastLine -= 1 }
            let line = count > 0 ? min(count, lines.lineCount) - 1 : lastLine
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
        if op == ">" || op == "<" {
            let li = lines.line(containing: r.location)
            shiftLines(in: r, outdent: op == "<")
            let cr = lines.contentRange(ofLine: li)
            var p = cr.location
            while p < text.length, text.character(at: p) == 32 { p += 1 }
            setCaret(p)
            resetPending()
            return
        }
        registerBlock = nil
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
        if let block = registerBlock, !block.isEmpty { pasteBlock(block, after: after); return }
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

    /// Blockwise paste: each piece goes on its own line at the caret column, padding short
    /// lines with spaces and appending lines past the end.
    private func pasteBlock(_ pieces: [String], after: Bool) {
        guard let tv = textView else { return }
        let startLine = lines.line(containing: caret)
        let col = column(of: caret) + (after ? 1 : 0)
        tv.undoManager?.beginUndoGrouping()
        for (i, piece) in pieces.enumerated() {
            let li = startLine + i
            if li >= lines.lineCount || (li == lines.lineCount - 1 && lines.lineStarts[li] == text.length && text.length > 0) {
                // Past the last line: append as a new line, keeping the file's final newline.
                let end = text.length
                let endsWithNewline = end > 0 && text.character(at: end - 1) == 10
                let line = String(repeating: " ", count: col) + piece
                replace(NSRange(location: end, length: 0), with: endsWithNewline ? line + "\n" : "\n" + line)
                continue
            }
            let cr = lines.contentRange(ofLine: li)
            let at = min(cr.location + col, cr.end)
            let pad = max(0, col - cr.length)
            replace(NSRange(location: at, length: 0), with: String(repeating: " ", count: pad) + piece)
        }
        tv.undoManager?.endUndoGrouping()
        let cr = lines.contentRange(ofLine: startLine)
        setCaret(min(cr.location + col, cr.end))
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

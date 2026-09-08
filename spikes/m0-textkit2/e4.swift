import AppKit
import Foundation

let TINY = NSFont.systemFont(ofSize: 0.01)
func hide(_ out: NSMutableAttributedString, _ r: NSRange) {
    out.addAttributes([.font: TINY, .foregroundColor: NSColor.clear], range: r)
}

final class Delegate: NSObject, NSTextContentStorageDelegate {
    var revealed: Int = -1
    var calls = 0
    func textContentStorage(_ tcs: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        calls += 1
        guard let backing = tcs.textStorage else { return nil }
        if range.location == revealed { return nil }
        let out = NSMutableAttributedString(attributedString: backing.attributedSubstring(from: range))
        let ns = out.string as NSString
        // fence line: hide the whole line INCLUDING its newline
        if ns.hasPrefix("```") { hide(out, NSRange(location: 0, length: out.length)); return NSTextParagraph(attributedString: out) }
        // bold pairs
        var pairs: [(NSRange, NSRange)] = []; var scan = 0
        while true {
            let a = ns.range(of: "**", options: [], range: NSRange(location: scan, length: ns.length - scan))
            if a.location == NSNotFound { break }
            let b = ns.range(of: "**", options: [], range: NSRange(location: a.location + 2, length: ns.length - a.location - 2))
            if b.location == NSNotFound { break }
            pairs.append((a, b)); scan = b.location + 2
        }
        for (a, b) in pairs {
            out.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13),
                             range: NSRange(location: a.location + 2, length: b.location - a.location - 2))
            hide(out, a); hide(out, b)
        }
        var h = 0
        while h < ns.length && ns.character(at: h) == 35 { h += 1 }
        if h > 0 && h < ns.length && ns.character(at: h) == 32 {
            out.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 20), range: NSRange(location: 0, length: out.length))
            hide(out, NSRange(location: 0, length: h + 1))
        }
        return NSTextParagraph(attributedString: out)
    }
}

func build(_ text: String, width: CGFloat = 600) -> (NSTextStorage, NSTextContentStorage, NSTextLayoutManager, Delegate) {
    let backing = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
    let storage = NSTextContentStorage(); let del = Delegate()
    storage.delegate = del; storage.textStorage = backing
    let lm = NSTextLayoutManager()
    let c = NSTextContainer(size: CGSize(width: width, height: 1e7)); c.lineFragmentPadding = 0
    lm.textContainer = c; storage.addTextLayoutManager(lm)
    return (backing, storage, lm, del)
}

// ── E8: whole-line concealment (fence lines) ──
print("════════ E8 · whole-line concealment (``` fences) ════════")
let fenced = "Intro paragraph.\n```swift\nlet x = 1\n```\nAfter."
do {
    let (_, storage, lm, _) = build(fenced)
    func off(_ l: NSTextLocation) -> Int { storage.offset(from: storage.documentRange.location, to: l) }
    lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { f in
        let el = f.textElement!.elementRange!
        print(String(format: "  SRC %2d..<%-3d y=%6.2f h=%6.2f  %@", off(el.location), off(el.endLocation),
                     f.layoutFragmentFrame.origin.y, f.layoutFragmentFrame.height,
                     (f.textLineFragments.first?.attributedString.string ?? "").debugDescription))
        return true
    }
}

// ── E9: soft wrap with concealed markers near the wrap boundary ──
print("\n════════ E9 · soft wrapping with concealed markers ════════")
do {
    let long = "This is a fairly long paragraph with **emphasis right about here** so that the wrap point lands near a concealed marker and we can see whether line breaking stays sane."
    let (_, storage, lm, _) = build(long, width: 260)
    func off(_ l: NSTextLocation) -> Int { storage.offset(from: storage.documentRange.location, to: l) }
    lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { f in
        for lf in f.textLineFragments {
            print(String(format: "  line w=%6.1f  %@", lf.typographicBounds.width, lf.attributedString.attributedSubstring(from: lf.characterRange).string.debugDescription))
        }
        return true
    }
}

// ── E10: performance on a large document ──
print("\n════════ E10 · performance ════════")
func mkDoc(mb: Int) -> String {
    let unit = """
    # Section heading
    Some **bold** text and a plain sentence that runs on for a while to look like prose.
    - a list item
    - another list item

    ```swift
    let x = 1
    ```

    """
    var s = ""; s.reserveCapacity(mb * 1_048_576 + 4096)
    while s.utf8.count < mb * 1_048_576 { s += unit }
    return s
}
for mb in [1, 10] {
    let text = mkDoc(mb: mb)
    var t = Date()
    let (backing, storage, lm, del) = build(text)
    let tBuild = Date().timeIntervalSince(t)

    // viewport-sized layout (~1000pt tall window)
    t = Date()
    var laid = 0
    lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { f in
        laid += 1
        return f.layoutFragmentFrame.maxY < 1000
    }
    let tViewport = Date().timeIntervalSince(t)

    // a single-character edit
    t = Date()
    storage.performEditingTransaction {
        backing.replaceCharacters(in: NSRange(location: 40, length: 0), with: "x")
    }
    lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { f in
        f.layoutFragmentFrame.maxY < 1000
    }
    let tEdit = Date().timeIntervalSince(t)

    // reveal toggle: invalidate one paragraph
    del.calls = 0
    t = Date()
    del.revealed = 18
    storage.performEditingTransaction { backing.edited(.editedAttributes, range: NSRange(location: 18, length: 20), changeInLength: 0) }
    lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { f in
        f.layoutFragmentFrame.maxY < 1000
    }
    let tReveal = Date().timeIntervalSince(t)

    print(String(format: "  %2d MB (%d chars): build %.1f ms | viewport layout %.1f ms (%d frags) | 1-char edit %.2f ms | reveal toggle %.2f ms (%d paragraphs rebuilt)",
                 mb, backing.length, tBuild * 1000, tViewport * 1000, laid, tEdit * 1000, tReveal * 1000, del.calls))
}

// full-document layout worst case, 10 MB
do {
    let text = mkDoc(mb: 10)
    let (_, _, lm, _) = build(text)
    let t = Date()
    lm.ensureLayout(for: lm.documentRange)
    print(String(format: "  10 MB FULL document layout (worst case, should never run interactively): %.0f ms", Date().timeIntervalSince(t) * 1000))
}

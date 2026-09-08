import AppKit
import Foundation

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let TINY = NSFont.systemFont(ofSize: 0.01)
func hide(_ o: NSMutableAttributedString, _ r: NSRange) {
    o.addAttributes([.font: TINY, .foregroundColor: NSColor.clear], range: r)
}

final class Delegate: NSObject, NSTextContentStorageDelegate {
    var revealedParagraphRange: NSRange? = nil
    func textContentStorage(_ tcs: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let backing = tcs.textStorage else { return nil }
        if let rv = revealedParagraphRange, NSIntersectionRange(rv, range).length > 0 || rv.location == range.location {
            return nil  // reveal verbatim
        }
        let out = NSMutableAttributedString(attributedString: backing.attributedSubstring(from: range))
        let ns = out.string as NSString
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

// Build a real NSTextView on our own content storage
let storage = NSTextContentStorage()
let del = Delegate()
storage.delegate = del
storage.textStorage = NSTextStorage(string: "# Title\nSome **bold** here.\nTail line.",
                                    attributes: [.font: NSFont.systemFont(ofSize: 13)])
let lm = NSTextLayoutManager()
let container = NSTextContainer(size: CGSize(width: 500, height: 1e6))
container.lineFragmentPadding = 0
lm.textContainer = container
storage.addTextLayoutManager(lm)

let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), textContainer: container)
tv.isEditable = true
tv.isRichText = false
tv.isAutomaticQuoteSubstitutionEnabled = false
tv.isAutomaticDashSubstitutionEnabled = false
tv.isAutomaticTextReplacementEnabled = false

let win = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: false)
win.contentView = NSView(frame: tv.frame)
win.contentView?.addSubview(tv)
win.layoutIfNeeded()

func src() -> String { storage.textStorage!.string }
func offOf(_ l: NSTextLocation) -> Int { storage.offset(from: storage.documentRange.location, to: l) }

print("════════ E11 · live NSTextView ════════")
print("uses TextKit 2   :", tv.textLayoutManager != nil)
print("our storage bound:", tv.textLayoutManager === lm)
print("initial source   :", src().debugDescription)

// Type at the end of "Tail line."
tv.setSelectedRange(NSRange(location: src().count, length: 0))
tv.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
print("\nafter typing '!' at end:")
print("  source         :", src().debugDescription)

// Type inside the concealed bold paragraph (source offset 20, inside 'bold')
tv.setSelectedRange(NSRange(location: 20, length: 0))
del.revealedParagraphRange = NSRange(location: 8, length: 19)   // reveal paragraph 1
storage.performEditingTransaction {
    storage.textStorage!.edited(.editedAttributes, range: NSRange(location: 8, length: 19), changeInLength: 0)
}
tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
print("\nafter typing 'X' inside revealed **bold**:")
print("  source         :", src().debugDescription)
print("  selectedRange  :", tv.selectedRange())

// What does the text view report as its string / what would Copy produce?
print("\ncopy fidelity:")
print("  tv.string      :", tv.string.debugDescription)
let sel = NSRange(location: 8, length: 18)
print("  attributedSubstring(8,18):", tv.attributedSubstring(forProposedRange: sel, actualRange: nil)?.string.debugDescription ?? "nil")

// Selection geometry across a concealed paragraph
del.revealedParagraphRange = nil
storage.performEditingTransaction {
    storage.textStorage!.edited(.editedAttributes, range: NSRange(location: 0, length: storage.textStorage!.length), changeInLength: 0)
}
tv.setSelectedRange(NSRange(location: 0, length: 0))
print("\ncaret rects walking offsets 0..10 (all concealed, '# ' hidden):")
for i in 0...10 {
    let l = storage.location(storage.documentRange.location, offsetBy: i)!
    var rect = CGRect.zero
    lm.enumerateTextSegments(in: NSTextRange(location: l), type: .selection, options: []) { _, r, _, _ in rect = r; return false }
    print(String(format: "  offset %2d -> caret x=%6.2f", i, rect.origin.x))
}

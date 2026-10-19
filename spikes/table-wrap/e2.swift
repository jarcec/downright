// Spike: a same-length substitution of `|` with U+2028 (LINE SEPARATOR) in the display
// paragraph — does the row break into stacked cell lines, and does the caret mapping hold?
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let font = NSFont.systemFont(ofSize: 13)
let row = "Legal name|Estuary Technologies, Inc.; product renamed Estuary Flow to Estuary on Mar 11, 2026 and more words to wrap|[18]"
let text = "Before.\n" + row + "\nAfter."

final class Delegate: NSObject, NSTextContentStorageDelegate {
    func textContentStorage(_ tcs: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let backing = tcs.textStorage else { return nil }
        let out = NSMutableAttributedString(attributedString: backing.attributedSubstring(from: range))
        guard out.string.hasPrefix("Legal") else { return nil }
        let ns = out.string as NSString
        for i in 0..<ns.length where ns.character(at: i) == 124 {   // '|'
            out.replaceCharacters(in: NSRange(location: i, length: 1), with: "\u{2028}")
        }
        let ps = NSMutableParagraphStyle(); ps.headIndent = 110; ps.lineBreakMode = .byWordWrapping
        out.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: out.length))
        return NSTextParagraph(attributedString: out)
    }
}
let storage = NSTextContentStorage(); let del = Delegate(); storage.delegate = del
storage.textStorage = NSTextStorage(string: text, attributes: [.font: font])
let lm = NSTextLayoutManager()
let container = NSTextContainer(size: CGSize(width: 420, height: 1e6)); container.lineFragmentPadding = 0
lm.textContainer = container; storage.addTextLayoutManager(lm)
let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 400), textContainer: container); tv.textContainerInset = .zero
let win = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: false)
win.contentView = NSView(frame: tv.frame); win.contentView?.addSubview(tv); win.layoutIfNeeded()
lm.ensureLayout(for: lm.documentRange)
func loc(_ o: Int) -> NSTextLocation { storage.location(storage.documentRange.location, offsetBy: o)! }
func caret(_ o: Int) -> CGRect { var r = CGRect.zero; lm.enumerateTextSegments(in: NSTextRange(location: loc(o)), type: .selection, options: [.rangeNotRequired]) { _, f, _, _ in r = f; return false }; return r }
lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { f in
    print(f.layoutFragmentFrame, "lines:", f.textLineFragments.count)
    for lf in f.textLineFragments { print("   ", lf.characterRange, lf.typographicBounds, (lf.attributedString.string as NSString).substring(with: lf.characterRange).replacingOccurrences(of: "\u{2028}", with: "⏎").debugDescription) }
    return true
}
let rs = (text as NSString).range(of: row).location
for o in [rs, rs + 10, rs + 11, rs + 60, rs + 104, rs + 105] {
    let c = caret(o); print(String(format: "caret off %3d -> x %6.1f y %6.1f", o, c.minX, c.minY), (text as NSString).substring(with: NSRange(location: o, length: 3)).debugDescription)
}
tv.setSelectedRange(NSRange(location: rs + 60, length: 0)); tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
print("typed at 60 ->", (storage.textStorage!.string as NSString).substring(with: NSRange(location: rs + 55, length: 10)).debugDescription)

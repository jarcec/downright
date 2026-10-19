// Does a negative kern on a row's first character shift the whole row left under TextKit 2,
// with caret rects and hit-testing following?
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let font = NSFont.systemFont(ofSize: 13)
let row = "| alpha | beta gamma delta | epsilon zeta eta theta iota kappa lambda |"
let text = "Before.\n" + row + "\nAfter."
let shift = CGFloat(CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1])! : 120)

final class Delegate: NSObject, NSTextContentStorageDelegate {
    func textContentStorage(_ tcs: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let backing = tcs.textStorage else { return nil }
        let out = NSMutableAttributedString(attributedString: backing.attributedSubstring(from: range))
        guard out.string.hasPrefix("| alpha") else { return nil }
        let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byClipping
        switch ProcessInfo.processInfo.environment["MODE"] ?? "kern" {
        case "indent": ps.headIndent = -shift; ps.firstLineHeadIndent = -shift
        case "container": break
        default: out.addAttribute(.kern, value: -shift, range: NSRange(location: 0, length: 1))
        }
        out.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: out.length))
        return NSTextParagraph(attributedString: out)
    }
}
let storage = NSTextContentStorage(); let del = Delegate(); storage.delegate = del
storage.textStorage = NSTextStorage(string: text, attributes: [.font: font])
let lm = NSTextLayoutManager()
final class ShiftingContainer: NSTextContainer {
    var rowRange = NSRange(location: 0, length: 0)
    var shift: CGFloat = 0
    var calls = 0
    override func lineFragmentRect(forProposedRect proposedRect: CGRect, at characterIndex: Int, writingDirection baseWritingDirection: NSWritingDirection, remaining remainingRect: UnsafeMutablePointer<CGRect>?) -> CGRect {
        calls += 1
        var r = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex, writingDirection: baseWritingDirection, remaining: remainingRect)
        if NSLocationInRange(characterIndex, rowRange) {
            r.origin.x -= shift
            switch ProcessInfo.processInfo.environment["WIDTH"] ?? "grow" {
            case "same": break
            case "huge": r.size.width = 1e7
            case "extra": r.size.width += shift + 1000
            default: r.size.width += shift
            }
        }
        if ProcessInfo.processInfo.environment["TRACE"] != nil { print("   lfr idx", characterIndex, "proposed", proposedRect, "->", r, "remaining", remainingRect?.pointee ?? .null) }
        return r
    }
}
let mode = ProcessInfo.processInfo.environment["MODE"] ?? "kern"
let container = ShiftingContainer(size: CGSize(width: 300, height: 1e6)); container.lineFragmentPadding = 0
if mode == "container" { container.shift = shift; container.rowRange = (text as NSString).range(of: row) }
container.widthTracksTextView = false
lm.textContainer = container; storage.addTextLayoutManager(lm)
let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), textContainer: container); tv.textContainerInset = .zero
let win = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: false)
win.contentView = NSView(frame: tv.frame); win.contentView?.addSubview(tv); win.layoutIfNeeded()
lm.ensureLayout(for: lm.documentRange)
func loc(_ o: Int) -> NSTextLocation { storage.location(storage.documentRange.location, offsetBy: o)! }
func caret(_ o: Int) -> CGRect { var r = CGRect.zero; lm.enumerateTextSegments(in: NSTextRange(location: loc(o)), type: .selection, options: [.rangeNotRequired]) { _, f, _, _ in r = f; return false }; return r }
lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { f in
    print("frame", f.layoutFragmentFrame, "surface", f.renderingSurfaceBounds)
    for lf in f.textLineFragments { print("   line", lf.characterRange, lf.typographicBounds, lf.glyphOrigin) }
    return true
}
let rs = (text as NSString).range(of: row).location
for name in ["alpha", "beta", "epsilon", "lambda"] {
    let o = rs + (row as NSString).range(of: name).location
    let c = caret(o); print(String(format: "%-8@ off %3d  caret x %7.1f  y %5.1f", name, o, c.minX, c.minY))
}
// Hit-test a point on "epsilon" as shifted, and the point to the left of the container.
for name in ["beta", "epsilon"] {
    let o = rs + (row as NSString).range(of: name).location
    let c = caret(o)
    let p = CGPoint(x: c.minX + 2, y: c.midY)
    let sel = lm.textSelectionNavigation.textSelections(interactingAt: p, inContainerAt: lm.documentRange.location, anchors: [], modifiers: [], selecting: false, bounds: .zero)
    let hit = sel.first?.textRanges.first.map { storage.offset(from: storage.documentRange.location, to: $0.location) } ?? -1
    print(String(format: "hit at x %6.1f -> offset %3d (want %3d) %@", p.x, hit, o, hit == o ? "ok" : "MISMATCH"))
}
tv.setSelectedRange(NSRange(location: rs + (row as NSString).range(of: "beta").location, length: 0)); tv.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
print("container calls:", container.calls); print("typed ->", (storage.textStorage!.string as NSString).substring(with: NSRange(location: rs + 8, length: 8)).debugDescription)

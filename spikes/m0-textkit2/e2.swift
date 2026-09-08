import AppKit
import Foundation

func conceal(_ src: NSAttributedString) -> NSAttributedString {
    let out = NSMutableAttributedString(attributedString: src)
    var scan = 0
    while scan + 1 < out.length {
        let ns = out.string as NSString
        let r = ns.range(of: "**", options: [], range: NSRange(location: scan, length: ns.length - scan))
        if r.location == NSNotFound { break }
        let r2 = ns.range(of: "**", options: [], range: NSRange(location: r.location + 2, length: ns.length - r.location - 2))
        if r2.location == NSNotFound { break }
        out.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 13),
                         range: NSRange(location: r.location + 2, length: r2.location - r.location - 2))
        out.deleteCharacters(in: r2)
        out.deleteCharacters(in: r)
        scan = r.location
    }
    let ns2 = out.string as NSString
    var hashes = 0
    while hashes < ns2.length && ns2.character(at: hashes) == 35 { hashes += 1 }
    if hashes > 0 && hashes < ns2.length && ns2.character(at: hashes) == 32 {
        out.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 20), range: NSRange(location: 0, length: out.length))
        out.deleteCharacters(in: NSRange(location: 0, length: hashes + 1))
    }
    return out
}

final class Delegate: NSObject, NSTextContentStorageDelegate {
    var revealedLocation: Int = -1
    var calls: [NSRange] = []
    func textContentStorage(_ tcs: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        calls.append(range)
        guard let backing = tcs.textStorage else { return nil }
        if range.location == revealedLocation { return nil }
        return NSTextParagraph(attributedString: conceal(backing.attributedSubstring(from: range)))
    }
}

let doc = """
# Heading one
Some **bold** text here.
## Heading two
Another plain line.
"""
// source offsets:  para0 0..<14, para1 14..<39, para2 39..<54, para3 54..<73

let backing = NSTextStorage(string: doc, attributes: [.font: NSFont.systemFont(ofSize: 13)])
let storage = NSTextContentStorage()
let del = Delegate()
storage.delegate = del
storage.textStorage = backing

let lm = NSTextLayoutManager()
let container = NSTextContainer(size: CGSize(width: 600, height: 1e6))
container.lineFragmentPadding = 0
lm.textContainer = container
storage.addTextLayoutManager(lm)

func off(_ l: NSTextLocation) -> Int { storage.offset(from: storage.documentRange.location, to: l) }
func loc(_ i: Int) -> NSTextLocation { storage.location(storage.documentRange.location, offsetBy: i)! }

// force full layout
lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { _ in true }

print("=== E4: fragment geometry + coordinate spaces (all concealed) ===")
lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { frag in
    let el = frag.textElement!.elementRange!
    print(String(format: "elementRange(SRC) %2d..<%-3d  rangeInElement %2d..<%-3d  y=%6.1f h=%5.1f",
                 off(el.location), off(el.endLocation),
                 off(frag.rangeInElement.location), off(frag.rangeInElement.endLocation),
                 frag.layoutFragmentFrame.origin.y, frag.layoutFragmentFrame.height))
    for lf in frag.textLineFragments {
        print("      displayed: \(lf.attributedString.string.debugDescription)  charRange \(lf.characterRange)")
    }
    return true
}

print("\n=== E5: caret navigation right from source offset 12 (end of '# Heading one') ===")
let nav = lm.textSelectionNavigation
var sel = NSTextSelection(loc(12), affinity: .downstream)
for step in 1...8 {
    guard let next = nav.destinationSelection(for: sel, direction: .forward, destination: .character,
                                              extending: false, confined: false) else {
        print("  step \(step): nil"); break
    }
    sel = next
    let o = off(sel.textRanges[0].location)
    let ch = o < backing.length ? backing.string[backing.string.index(backing.string.startIndex, offsetBy: o)].debugDescription : "EOF"
    print("  step \(step): source offset \(o)   char there = \(ch)")
}

print("\n=== E6: hit-testing a point inside a concealed paragraph ===")
// paragraph 1 displayed as "Some bold text here." — click near x=40pt on its line
if let frag = lm.textLayoutFragment(for: CGPoint(x: 40, y: 30)) {
    let el = frag.textElement!.elementRange!
    print("  fragment at y=30 has elementRange(SRC) \(off(el.location))..<\(off(el.endLocation))")
    let localPoint = CGPoint(x: 40 - frag.layoutFragmentFrame.origin.x, y: 30 - frag.layoutFragmentFrame.origin.y)
    if let lf = frag.textLineFragments.first {
        let idx = lf.characterIndex(for: localPoint)
        print("  line displayed \(lf.attributedString.string.debugDescription)")
        print("  characterIndex(for:) -> \(idx)  == DISPLAY index into that string")
    }
}
let hit = nav.textSelections(interactingAt: CGPoint(x: 40, y: 30), inContainerAt: lm.documentRange.location,
                             anchors: [], modifiers: [], selecting: false, bounds: .zero)
if let h = hit.first { print("  textSelections(interactingAt:) -> source offset \(off(h.textRanges[0].location))") }

print("\n=== E7: switching reveal — how many paragraphs are re-created? ===")
del.calls.removeAll()
del.revealedLocation = 14   // reveal paragraph 1
let p1 = NSRange(location: 14, length: 25)
storage.performEditingTransaction {
    backing.edited(.editedAttributes, range: p1, changeInLength: 0)
}
lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { _ in true }
print("  delegate calls after revealing para1: \(del.calls.map { "\($0.location)..<\($0.location+$0.length)" })")
lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { frag in
    let el = frag.textElement!.elementRange!
    if let lf = frag.textLineFragments.first {
        print("  SRC \(off(el.location))..<\(off(el.endLocation)) displayed \(lf.attributedString.string.debugDescription)")
    }
    return true
}
print("\n  backing UNCHANGED: \(backing.string == doc)")

import AppKit
import Foundation

enum Mode { case baseline, zwsp, zeroFont, deleting }

let TINY = NSFont.systemFont(ofSize: 0.01)

func transform(_ src: NSAttributedString, mode: Mode) -> NSAttributedString? {
    if mode == .baseline { return nil }
    let out = NSMutableAttributedString(attributedString: src)

    func hide(_ r: NSRange) {
        switch mode {
        case .zwsp:
            let repl = NSAttributedString(string: String(repeating: "\u{200B}", count: r.length),
                                          attributes: [.font: NSFont.systemFont(ofSize: 13)])
            out.replaceCharacters(in: r, with: repl)
        case .zeroFont:
            out.addAttributes([.font: TINY, .kern: 0.0], range: r)
        case .deleting:
            out.deleteCharacters(in: r)
        case .baseline: break
        }
    }

    // bold markers (process back-to-front so ranges stay valid)
    var pairs: [(NSRange, NSRange)] = []
    let ns = out.string as NSString
    var scan = 0
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
    }
    for (a, b) in pairs.reversed() { hide(b); hide(a) }

    // heading markers
    var hashes = 0
    let ns2 = out.string as NSString
    while hashes < ns2.length && ns2.character(at: hashes) == 35 { hashes += 1 }
    if hashes > 0 && hashes < ns2.length && ns2.character(at: hashes) == 32 {
        out.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 20), range: NSRange(location: 0, length: out.length))
        hide(NSRange(location: 0, length: hashes + 1))
    }
    return out
}

final class Delegate: NSObject, NSTextContentStorageDelegate {
    var mode: Mode = .baseline
    var calls = 0
    func textContentStorage(_ tcs: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        calls += 1
        guard let backing = tcs.textStorage else { return nil }
        guard let t = transform(backing.attributedSubstring(from: range), mode: mode) else { return nil }
        return NSTextParagraph(attributedString: t)
    }
}

let doc = """
# Heading one
Some **bold** text here.
## Heading two
Another plain line.
"""

func run(_ mode: Mode, _ name: String) {
    print("\n════════ \(name) ════════")
    let backing = NSTextStorage(string: doc, attributes: [.font: NSFont.systemFont(ofSize: 13)])
    let storage = NSTextContentStorage()
    let del = Delegate(); del.mode = mode
    storage.delegate = del
    storage.textStorage = backing
    let lm = NSTextLayoutManager()
    let c = NSTextContainer(size: CGSize(width: 600, height: 1e6)); c.lineFragmentPadding = 0
    lm.textContainer = c
    storage.addTextLayoutManager(lm)
    func off(_ l: NSTextLocation) -> Int { storage.offset(from: storage.documentRange.location, to: l) }
    func loc(_ i: Int) -> NSTextLocation { storage.location(storage.documentRange.location, offsetBy: i)! }

    lm.ensureLayout(for: lm.documentRange)
    var n = 0
    var frames: [(Int, Int, CGFloat, CGFloat, String)] = []
    lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { f in
        n += 1
        let el = f.textElement!.elementRange!
        let disp = f.textLineFragments.first?.attributedString.string ?? "<none>"
        let w = f.textLineFragments.first?.typographicBounds.width ?? -1
        frames.append((off(el.location), off(el.endLocation), f.layoutFragmentFrame.origin.y, w, disp))
        return true
    }
    print("fragments enumerated: \(n)  (expected 4)")
    for (a, b, y, w, d) in frames {
        print(String(format: "  SRC %2d..<%-3d y=%6.1f w=%6.1f  %@", a, b, y, w, d.debugDescription))
    }

    // caret walk forward from offset 11
    let nav = lm.textSelectionNavigation
    var sel = NSTextSelection(loc(11), affinity: .downstream)
    var path: [Int] = [11]
    for _ in 1...10 {
        guard let nx = nav.destinationSelection(for: sel, direction: .forward, destination: .character,
                                                extending: false, confined: false) else { break }
        sel = nx; path.append(off(sel.textRanges[0].location))
    }
    print("  caret walk from 11: \(path)")
    print("  expected          : [11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21]")

    // hit test on the 2nd paragraph's line
    let y = frames.count > 1 ? frames[1].2 + 5 : 30
    if let f = lm.textLayoutFragment(for: CGPoint(x: 30, y: y)) {
        print("  hitTest y=\(Int(y)) -> fragment SRC \(off(f.textElement!.elementRange!.location))")
    } else { print("  hitTest y=\(Int(y)) -> nil  ❌") }
    let hits = nav.textSelections(interactingAt: CGPoint(x: 30, y: y), inContainerAt: lm.documentRange.location,
                                  anchors: [], modifiers: [], selecting: false, bounds: .zero)
    if let h = hits.first { print("  click at x=30 -> source offset \(off(h.textRanges[0].location))") }
    print("  backing pristine: \(backing.string == doc)")
}

run(.baseline, "A · BASELINE (no substitution)")
run(.deleting, "D · DELETING markers (display shorter than source)")
run(.zwsp,     "B · ZWSP replacement (length preserved)")
run(.zeroFont, "C · ZERO-SIZE FONT on markers (length preserved)")

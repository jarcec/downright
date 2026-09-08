import AppKit
import Foundation

// ── A deliberately naive concealer: strips ATX heading markers and ** pairs ──
func conceal(_ src: NSAttributedString) -> NSAttributedString {
    let s = src.string
    let out = NSMutableAttributedString(attributedString: src)
    // strip "** ... **"
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
    // strip leading "#+ "
    let ns2 = out.string as NSString
    var hashes = 0
    while hashes < ns2.length && ns2.character(at: hashes) == 35 { hashes += 1 }
    if hashes > 0 && hashes < ns2.length && ns2.character(at: hashes) == 32 {
        out.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 24),
                         range: NSRange(location: 0, length: out.length))
        out.deleteCharacters(in: NSRange(location: 0, length: hashes + 1))
    }
    return out
}

final class Delegate: NSObject, NSTextContentStorageDelegate {
    var revealedLocation: Int = -1
    var calls: [NSRange] = []

    func textContentStorage(_ tcs: NSTextContentStorage,
                            textParagraphWith range: NSRange) -> NSTextParagraph? {
        calls.append(range)
        guard let backing = tcs.textStorage else { return nil }
        if range.location == revealedLocation { return nil }   // reveal = use source verbatim
        let display = conceal(backing.attributedSubstring(from: range))
        return NSTextParagraph(attributedString: display)
    }
}

// ── Setup ──
let doc = """
# Heading one
Some **bold** text here.
## Heading two
Another plain line that is long enough to be interesting.
"""

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

lm.ensureLayout(for: lm.documentRange)

print("=== E1/E2/E3: substitution with SHORTER display strings ===")
print("backing length          :", backing.length)
print("backing string (repr)   :", backing.string.debugDescription)
print("delegate calls          :", del.calls.map { "\($0.location)..<\($0.location + $0.length)" })
print("")

func offset(_ loc: NSTextLocation) -> Int { storage.offset(from: storage.documentRange.location, to: loc) }

print("documentRange           : \(offset(lm.documentRange.location))..<\(offset(lm.documentRange.endLocation))")
print("")
print("--- layout fragments ---")
lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: []) { frag in
    let r = frag.rangeInElement
    let el = frag.textElement
    let elRange = el?.elementRange
    print("fragment srcRange \(offset(r.location))..<\(offset(r.endLocation))  " +
          "elementRange \(elRange.map { "\(offset($0.location))..<\(offset($0.endLocation))" } ?? "nil")  " +
          "frame \(frag.layoutFragmentFrame.integral)")
    for lf in frag.textLineFragments {
        print("    line charRange \(lf.characterRange)  displayed \(lf.attributedString.string.debugDescription)")
    }
    return true
}
print("")
print("--- backing store after layout (must be UNCHANGED) ---")
print(backing.string.debugDescription)

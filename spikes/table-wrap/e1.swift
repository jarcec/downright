// Spike: can a custom NSTextLayoutFragment present a table row as per-cell *wrapped*
// line fragments, and do caret geometry, hit-testing and arrow navigation follow?
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let font = NSFont.systemFont(ofSize: 13)
let row = "Alpha beta gamma|Second cell with quite a lot of words that must wrap onto several lines|Third"
let text = "Before the table.\n" + row + "\nAfter the table."
let columns: [CGFloat] = [0, 120, 300, 420]   // boundaries; 3 columns

/// A line fragment that carries its own CoreText metrics: a standalone NSTextLineFragment
/// has none (the layout manager fills them privately), so every geometry query is answered
/// from a CTLine over the fragment's own range.
final class CellLine: NSTextLineFragment {
    var origin = CGPoint.zero
    let ctLine: CTLine
    let ascent: CGFloat, descent: CGFloat, leading: CGFloat, width: CGFloat
    let range: NSRange
    let sub: NSAttributedString
    init(attributedString: NSAttributedString, range: NSRange, origin: CGPoint) {
        self.range = range
        self.origin = origin
        sub = attributedString.attributedSubstring(from: range)
        ctLine = CTLineCreateWithAttributedString(sub)
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        width = CGFloat(CTLineGetTypographicBounds(ctLine, &a, &d, &l))
        ascent = a; descent = d; leading = l
        super.init(attributedString: attributedString, range: range)
    }
    required init?(coder: NSCoder) { fatalError() }
    var lineHeight: CGFloat { ceil(ascent + descent + leading) }
    override var typographicBounds: CGRect { CGRect(x: origin.x, y: origin.y, width: width, height: lineHeight) }
    override var glyphOrigin: CGPoint { CGPoint(x: origin.x, y: origin.y + ascent) }
    override func locationForCharacter(at index: Int) -> CGPoint {
        let x = CTLineGetOffsetForStringIndex(ctLine, index - range.location, nil)
        return CGPoint(x: origin.x + x, y: origin.y)
    }
    override func characterIndex(for point: CGPoint) -> Int {
        let i = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: point.x - origin.x, y: 0))
        return i == kCFNotFound ? range.location : i + range.location
    }
    override func fractionOfDistanceThroughGlyph(for point: CGPoint) -> CGFloat {
        let i = characterIndex(for: point)
        let x0 = CTLineGetOffsetForStringIndex(ctLine, i - range.location, nil)
        let x1 = CTLineGetOffsetForStringIndex(ctLine, i - range.location + 1, nil)
        return x1 > x0 ? max(0, min(1, (point.x - origin.x - x0) / (x1 - x0))) : 0
    }
    override func draw(at point: CGPoint, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        sub.draw(at: CGPoint(x: point.x + origin.x, y: point.y + origin.y))
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class RowFragment: NSTextLayoutFragment {
    var lines: [CellLine] = []
    var height: CGFloat = 0
    func build() {
        guard lines.isEmpty, let para = textElement as? NSTextParagraph else { return }
        let str = para.attributedString
        let ns = str.string as NSString
        var cellStart = 0
        var column = 0
        var maxY: CGFloat = 0
        var sepIndex = 0
        while cellStart <= ns.length {
            var sep = ns.range(of: "|", range: NSRange(location: cellStart, length: ns.length - cellStart))
            if sep.location == NSNotFound { sep = NSRange(location: ns.length, length: 0) }
            // strip trailing newline from the last cell
            var cellRange = NSRange(location: cellStart, length: sep.location - cellStart)
            if cellRange.length > 0, ns.character(at: cellRange.location + cellRange.length - 1) == 10 { cellRange.length -= 1 }
            let width = columns[column + 1] - columns[column] - 12
            let ts = CTTypesetterCreateWithAttributedString(str)
            var pos = cellRange.location
            var y: CGFloat = 0
            while pos < cellRange.location + cellRange.length {
                let count = CTTypesetterSuggestLineBreak(ts, pos, Double(width))
                let n = min(count, cellRange.location + cellRange.length - pos)
                let lf = CellLine(attributedString: str, range: NSRange(location: pos, length: n), origin: CGPoint(x: columns[column] + 6, y: y))
                lines.append(lf)
                y += lf.lineHeight
                pos += n
            }
            // separator character itself: a zero-width-ish line at the column rule
            if sep.length > 0 {
                lines.append(CellLine(attributedString: str, range: sep, origin: CGPoint(x: columns[column + 1] - 4, y: 0)))
                sepIndex += 1
            }
            maxY = max(maxY, y)
            cellStart = sep.location + sep.length
            if sep.length == 0 { break }
            column += 1
        }
        height = maxY
        lines.sort { $0.characterRange.location < $1.characterRange.location }
    }
    static let useSuperLines = ProcessInfo.processInfo.environment["SPIKE_SUPERLINES"] != nil
    override var textLineFragments: [NSTextLineFragment] { build(); return Self.useSuperLines ? super.textLineFragments : lines }
    override var layoutFragmentFrame: CGRect { build(); var f = super.layoutFragmentFrame; f.size.height = height; return f }
    override var renderingSurfaceBounds: CGRect { build(); return CGRect(x: 0, y: 0, width: columns.last!, height: height) }
    override func draw(at point: CGPoint, in context: CGContext) {
        build()
        for lf in lines { lf.draw(at: point, in: context) }
    }
}

final class LMDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(_ lm: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement) -> NSTextLayoutFragment {
        if let p = textElement as? NSTextParagraph, p.attributedString.string.hasPrefix("Alpha") {
            return RowFragment(textElement: textElement, range: textElement.elementRange)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }
}

let storage = NSTextContentStorage()
storage.textStorage = NSTextStorage(string: text, attributes: [.font: font])
let lm = NSTextLayoutManager()
let lmd = LMDelegate()
lm.delegate = lmd
let container = NSTextContainer(size: CGSize(width: 500, height: 1e6))
container.lineFragmentPadding = 0
lm.textContainer = container
storage.addTextLayoutManager(lm)
let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), textContainer: container)
tv.textContainerInset = .zero
let win = NSWindow(contentRect: tv.frame, styleMask: [.titled], backing: .buffered, defer: false)
win.contentView = NSView(frame: tv.frame); win.contentView?.addSubview(tv); win.layoutIfNeeded()
lm.ensureLayout(for: lm.documentRange)

func off(_ l: NSTextLocation) -> Int { storage.offset(from: storage.documentRange.location, to: l) }
func loc(_ o: Int) -> NSTextLocation { storage.location(storage.documentRange.location, offsetBy: o)! }
func caret(_ o: Int) -> CGRect {
    var r = CGRect.zero
    lm.enumerateTextSegments(in: NSTextRange(location: loc(o)), type: .selection, options: [.rangeNotRequired]) { _, f, _, _ in r = f; return false }
    return r
}
let rowStart = (text as NSString).range(of: row).location
let cell2Start = rowStart + (row as NSString).range(of: "Second").location
let cell3Start = rowStart + (row as NSString).range(of: "Third").location

print("frames:")
lm.enumerateTextLayoutFragments(from: lm.documentRange.location, options: [.ensuresLayout]) { f in
    print("  ", type(of: f), f.layoutFragmentFrame, "lines:", f.textLineFragments.count); return true
}
print("\ncaret rects (x should sit in the cell's column, y on the wrapped line):")
for (name, o) in [("row start", rowStart), ("cell2 start", cell2Start), ("cell2 +40 chars", cell2Start + 40), ("cell3 start", cell3Start), ("after table", cell3Start + 6)] {
    print(String(format: "  %-16@ off %3d  x %6.1f  y %6.1f  h %5.1f", name, o, caret(o).minX, caret(o).minY, caret(o).height))
}

print("\nhit test (point -> offset):")
let nav = lm.textSelectionNavigation
func hit(_ p: CGPoint) -> Int {
    let sels = nav.textSelections(interactingAt: p, inContainerAt: lm.documentRange.location, anchors: [], modifiers: [], selecting: false, bounds: .zero)
    return sels.first?.textRanges.first.map { off($0.location) } ?? -1
}
for (name, p) in [("cell1 line1", CGPoint(x: 10, y: 16 + 8)), ("cell2 line2", CGPoint(x: 130, y: 16 + 16 + 8)), ("cell2 line3", CGPoint(x: 130, y: 16 + 32 + 8)), ("cell3", CGPoint(x: 310, y: 16 + 8)), ("below cell3 (empty)", CGPoint(x: 310, y: 16 + 32 + 8))] {
    let o = hit(p)
    print("  \(name): \(p) -> \(o)  (\(o >= 0 ? String((text as NSString).substring(with: NSRange(location: o, length: min(8, text.utf16.count - o)))) : "?"))")
}

print("\narrow navigation from cell2 start:")
var sel = NSTextSelection(loc(cell2Start), affinity: .downstream)
for dir in [NSTextSelectionNavigation.Direction.down, .down, .up] {
    if let d = nav.destinationSelection(for: sel, direction: dir, destination: .character, extending: false, confined: false) {
        sel = d
        let o = off(d.textRanges[0].location)
        print("  \(dir == .down ? "down" : "up  ") -> off \(o) '\((text as NSString).substring(with: NSRange(location: o, length: min(10, text.utf16.count - o))))'")
    } else { print("  \(dir): nil") }
}

import AppKit

/// Gutter showing *source* line numbers, laid out beside the scroll view (not as an
/// `NSRulerView`: NSScrollView's ruler tiling shifted the clip view's bounds and the
/// TextKit 2 viewport stopped rendering). One number per paragraph fragment; concealed
/// zero-height lines are skipped; wrapped paragraphs are numbered once.
@MainActor
public final class LineNumberGutterView: NSView {
    weak var controller: EditorController?
    private var digitWidth: CGFloat = 8
    private var widthConstraint: NSLayoutConstraint?

    public var font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    public init(controller: EditorController) {
        self.controller = controller
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let w = widthAnchor.constraint(equalToConstant: 40)
        w.isActive = true
        widthConstraint = w
        recomputeThickness()

        // Redraw whenever the text scrolls or resizes.
        let clip = controller.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(needsRedraw(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(needsRedraw(_:)), name: NSView.frameDidChangeNotification, object: controller.textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    @objc private func needsRedraw(_ note: Notification) { needsDisplay = true }

    /// Current width in points (0 when hidden).
    public var thickness: CGFloat { widthConstraint?.constant ?? 0 }

    /// Widen for the digit count of the document.
    public func recomputeThickness() {
        let lines = max(1, controller?.lines.lineCount ?? 1)
        let digits = max(2, String(lines).count)
        let t = ceil(CGFloat(digits) * digitWidth + 18)
        if let w = widthConstraint, abs(t - w.constant) > 0.5 { w.constant = t }
    }

    /// Click on a heading's line number toggles its fold.
    public override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return super.mouseDown(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        let tv = c.textView
        let inTV = tv.convert(p, from: self)
        let point = CGPoint(x: 0, y: inTV.y - tv.textContainerInset.height)
        guard let frag = c.layoutManager.textLayoutFragment(for: point), let element = frag.textElement?.elementRange else { return }
        let offset = c.contentStorage.offset(from: c.contentStorage.documentRange.location, to: element.location)
        let line = c.lines.line(containing: offset)
        if c.foldableBlock(atLine: line) != nil { c.toggleFold(atLine: line); needsDisplay = true }
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let c = controller, let window else { return }
        let tv = c.textView
        let inset = tv.textContainerInset
        let visible = tv.visibleRect
        let lm = c.layoutManager
        let caretLine = c.lines.line(containing: tv.selectedRange().location)
        let width = bounds.width

        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]
        let current: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]

        let start = CGPoint(x: 0, y: max(0, visible.minY - inset.height))
        guard let firstFragment = lm.textLayoutFragment(for: start) else { return }
        _ = window
        lm.enumerateTextLayoutFragments(from: firstFragment.rangeInElement.location, options: [.ensuresLayout]) { f in
            let frame = f.layoutFragmentFrame
            let yInTextView = frame.minY + inset.height
            if yInTextView > visible.maxY { return false }
            guard frame.height > 0, let element = f.textElement?.elementRange else { return true }
            let offset = c.contentStorage.offset(from: c.contentStorage.documentRange.location, to: element.location)
            let line = c.lines.line(containing: offset)
            let label = "\(line + 1)" as NSString
            let attrs = line == caretLine ? current : normal
            let size = label.size(withAttributes: attrs)
            // Fold chevron for headings / frontmatter: ▸ when folded, ▾ otherwise
            if c.foldableBlock(atLine: line) != nil {
                let folded = c.isFolded(line: line)
                let chev = (folded ? "▸" : "▾") as NSString
                let cattrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: folded ? NSColor.secondaryLabelColor : NSColor.quaternaryLabelColor]
                let cs = chev.size(withAttributes: cattrs)
                let cy = self.convert(NSPoint(x: 0, y: yInTextView), from: tv).y + ((f.textLineFragments.first?.typographicBounds.height ?? frame.height) - cs.height) / 2
                chev.draw(at: NSPoint(x: 3, y: cy), withAttributes: cattrs)
            }
            // Centre on the first text line; for lines whose text is concealed (rules) the
            // line is ~0pt tall, so centre on the whole fragment instead.
            var lineHeight = f.textLineFragments.first?.typographicBounds.height ?? frame.height
            if lineHeight < size.height { lineHeight = frame.height }
            let y = self.convert(NSPoint(x: 0, y: yInTextView), from: tv).y + (lineHeight - size.height) / 2
            label.draw(at: NSPoint(x: width - size.width - 8, y: y), withAttributes: attrs)
            return true
        }
    }
}

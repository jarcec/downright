import AppKit

/// The selection highlight, drawn above the text. NSTextView draws its own beneath the
/// text, where code spans, code blocks and quotes paint over it; that one is hidden
/// (see `MarkdownTextView.hideSystemSelection`) and this view draws the selection instead.
@MainActor
final class SelectionOverlayView: NSView {
    weak var textView: MarkdownTextView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let tv = textView, let tlm = tv.textLayoutManager, let storage = tlm.textContentManager else { return }
        let ranges = tv.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else { return }
        selectionColor(for: tv).setFill()
        let origin = tv.textContainerOrigin
        let doc = storage.documentRange.location
        for r in ranges {
            guard let start = storage.location(doc, offsetBy: r.location),
                  let end = storage.location(start, offsetBy: r.length),
                  let range = NSTextRange(location: start, end: end) else { continue }
            tlm.enumerateTextSegments(in: range, type: .selection, options: [.rangeNotRequired]) { _, frame, _, _ in
                let rect = frame.offsetBy(dx: origin.x, dy: origin.y)
                if rect.intersects(dirtyRect) { rect.fill(using: .sourceOver) }
                return true
            }
        }
    }

    /// The theme's marker while the text view has focus in the key window; a neutral
    /// wash otherwise, as AppKit dims an inactive selection.
    private func selectionColor(for tv: MarkdownTextView) -> NSColor {
        let theme = tv.controller?.theme ?? Theme()
        let active = tv.window?.isKeyWindow == true && tv.window?.firstResponder === tv
        return active ? theme.markerColor.withAlphaComponent(0.25) : theme.secondaryColor.withAlphaComponent(0.15)
    }
}

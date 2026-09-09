import Foundation
import MarkdownKit

/// PRD §7.1 / TRD §7. A pure function of the selection and the block structure.
public enum RevealPolicy {
    /// Source ranges (paragraph-aligned, merged, sorted) to display as raw source.
    ///
    /// 1. Every paragraph (source line) intersecting a selection reveals.
    /// 2. A revealed line inside a fenced code block reveals the whole block. Tables are the
    ///    exception to reveal: their structure never reveals, only the caret's cell (handled
    ///    by the decoration layer), so they are not widened here.
    public static func revealedRanges(selections: [NSRange], document: Document, lines: LineIndex) -> [NSRange] {
        var out: [NSRange] = []
        for sel in selections {
            let first = lines.line(containing: min(sel.location, lines.length))
            let lastOffset = sel.length > 0 ? sel.end - 1 : sel.location
            let last = lines.line(containing: min(lastOffset, lines.length))
            var start = lines.paragraphRange(ofLine: first).location
            var end = lines.paragraphRange(ofLine: last).end
            // Whole-construct reveal
            for line in first...last {
                let loc = lines.lineStarts[line]
                for block in document.path(containing: loc) {
                    switch block.kind {
                    case .fencedCode:
                        start = min(start, block.range.location)
                        end = max(end, block.range.end)
                    default: break
                    }
                }
            }
            out.append(NSRange(location: start, length: end - start))
        }
        return merge(out)
    }

    static func merge(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location }
        var out: [NSRange] = []
        for r in sorted {
            if let last = out.last, r.location <= last.location + last.length {
                out[out.count - 1] = NSRange(location: last.location, length: max(last.location + last.length, r.location + r.length) - last.location)
            } else {
                out.append(r)
            }
        }
        return out
    }
}


import Foundation

/// Line table for a UTF-16 buffer. Lines are split on `\n` only — the document layer
/// normalises line endings before text reaches the parser (TRD §8).
public struct LineIndex: Sendable {
    /// Start offset of each line. Always has at least one entry (0).
    public let lineStarts: [Int]
    public let length: Int

    public init(utf16 buf: [UInt16]) {
        var starts = [0]
        starts.reserveCapacity(buf.count / 40 + 1)
        for i in 0..<buf.count where buf[i] == C.newline {
            starts.append(i + 1)
        }
        self.lineStarts = starts
        self.length = buf.count
    }

    public init(_ string: String) {
        self.init(utf16: Array(string.utf16))
    }

    public var lineCount: Int { lineStarts.count }

    /// Index of the line containing `offset`. `offset == length` maps to the last line.
    public func line(containing offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Range of line `i` **including** its trailing newline (if any). This matches how
    /// `NSTextContentStorage` delimits paragraphs.
    public func paragraphRange(ofLine i: Int) -> NSRange {
        let start = lineStarts[i]
        let end = i + 1 < lineStarts.count ? lineStarts[i + 1] : length
        return NSRange(start, to: end)
    }

    /// Range of line `i` **excluding** its trailing newline.
    public func contentRange(ofLine i: Int) -> NSRange {
        let r = paragraphRange(ofLine: i)
        if i + 1 < lineStarts.count { return NSRange(location: r.location, length: r.length - 1) }
        return r
    }
}

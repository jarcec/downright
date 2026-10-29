import Foundation

/// GitHub's alerts: a block quote whose first line is `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`,
/// `[!WARNING]` or `[!CAUTION]` (any case, nothing else on the line).
public enum AlertKind: String, CaseIterable, Sendable {
    case note, tip, important, warning, caution

    /// How the title reads: `Note`, `Warning`.
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

extension Block {
    /// The alert this block quote is, and the range of its `[!KIND]` marker.
    public func alert(in source: NSString) -> (kind: AlertKind, marker: NSRange)? {
        guard case .blockQuote = kind, let first = children.first, case .paragraph = first.kind,
              let line = first.contentRanges.first else { return nil }
        let text = source.substring(with: line)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), trimmed.hasSuffix("]"),
              let kind = AlertKind(rawValue: String(trimmed.dropFirst(2).dropLast()).lowercased()) else { return nil }
        let lead = text.utf16.prefix { $0 == 32 || $0 == 9 }.count
        return (kind, NSRange(location: line.location + lead, length: trimmed.utf16.count))
    }
}

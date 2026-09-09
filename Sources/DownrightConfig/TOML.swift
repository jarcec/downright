import Foundation

/// The subset of TOML that a flat settings file needs: comments, `key = value` with
/// booleans, integers and basic strings, and `[section]` headers (flattened to
/// `section.key`). Deliberately small; not a general TOML implementation.
public enum TOMLValue: Equatable, Sendable {
    case bool(Bool)
    case int(Int)
    case string(String)

    public var serialized: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .string(let s):
            var out = "\""
            for ch in s {
                switch ch {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\t": out += "\\t"
                default: out.append(ch)
                }
            }
            return out + "\""
        }
    }
}

public enum TOML {
    /// Parse into a flat dictionary. Unknown or malformed lines are ignored.
    public static func parse(_ text: String) -> [String: TOMLValue] {
        var out: [String: TOMLValue] = [:]
        var section = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, let value = parseValue(rawValue) else { continue }
            out[section.isEmpty ? key : "\(section).\(key)"] = value
        }
        return out
    }

    /// Return `text` with the given flat keys set, editing existing `key = …` lines in
    /// place (comments and unknown keys survive) and appending the rest.
    public static func updating(_ text: String, with values: [String: TOMLValue]) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var remaining = values
        var section = ""
        for i in lines.indices {
            let stripped = stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("["), stripped.hasSuffix("]") {
                section = String(stripped.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = stripped.firstIndex(of: "=") else { continue }
            let key = stripped[..<eq].trimmingCharacters(in: .whitespaces)
            let full = section.isEmpty ? key : "\(section).\(key)"
            guard let newValue = remaining.removeValue(forKey: full) else { continue }
            // Keep any trailing comment on the line.
            let comment = trailingComment(lines[i])
            lines[i] = "\(key) = \(newValue.serialized)" + (comment.map { "  " + $0 } ?? "")
        }
        if !remaining.isEmpty {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            for key in remaining.keys.sorted() {
                lines.append("\(key) = \(remaining[key]!.serialized)")
            }
        }
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    // MARK: - Helpers

    private static func parseValue(_ s: String) -> TOMLValue? {
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if let i = Int(s) { return .int(i) }
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return .string(unescape(String(s.dropFirst().dropLast())))
        }
        if s.count >= 2, s.hasPrefix("'"), s.hasSuffix("'") {
            return .string(String(s.dropFirst().dropLast()))
        }
        // Lenient: a bare word is taken as a string so hand-written files still work.
        if !s.isEmpty, !s.contains(where: { $0.isWhitespace }) { return .string(s) }
        return nil
    }

    private static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let ch = it.next() {
            guard ch == "\\", let next = it.next() else { out.append(ch); continue }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            default: out.append("\\"); out.append(next)
            }
        }
        return out
    }

    /// Remove a `#` comment that is not inside a quoted string.
    private static func stripComment(_ line: String) -> String {
        var inQuote: Character? = nil
        var prev: Character = " "
        for (i, ch) in line.enumerated() {
            if let q = inQuote {
                if ch == q && prev != "\\" { inQuote = nil }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
            } else if ch == "#" {
                return String(line.prefix(i))
            }
            prev = ch
        }
        return line
    }

    private static func trailingComment(_ line: String) -> String? {
        let body = stripComment(line)
        guard body.count < line.count else { return nil }
        return String(line.dropFirst(body.count)).trimmingCharacters(in: .whitespaces)
    }
}

import Foundation

/// Lightweight syntax highlighting for fenced code blocks. One generic scanner driven by
/// small per-language specs — enough for the languages that show up in Markdown files,
/// deliberately not a full grammar. Tree-sitter can slot in behind the same protocol later.
public enum CodeToken: Equatable, Sendable {
    case keyword, type, string, comment, number, key, variable, added, removed, meta, tag, attribute
}

public protocol CodeHighlighter: Sendable {
    /// Token ranges (UTF-16 offsets into `code`) — non-overlapping, ascending.
    func tokens(in code: String) -> [(NSRange, CodeToken)]
}

public struct LanguageSpec: Sendable {
    public var keywords: Set<String> = []
    public var types: Set<String> = []
    public var lineComments: [String] = []
    public var blockComment: (open: String, close: String)? = nil
    public var stringQuotes: [Character] = ["\"", "'"]
    public var tripleQuotes = false
    public var caseInsensitiveKeywords = false
    /// Capitalised identifiers are types (Swift, Go, Rust, Java…).
    public var capitalizedTypes = false
    public var variablesWithDollar = false
    /// `identifier:` at the start of a line / object is a key (YAML, JSON, TOML).
    public var keysBeforeColon = false
    public var hashComments: Bool { lineComments.contains("#") }
}

public struct GenericHighlighter: CodeHighlighter {
    public let spec: LanguageSpec
    public init(_ spec: LanguageSpec) { self.spec = spec }

    public func tokens(in code: String) -> [(NSRange, CodeToken)] {
        let b = Array(code.utf16)
        var out: [(NSRange, CodeToken)] = []
        let n = b.count
        var i = 0
        var lineStart = true
        func starts(_ s: String, at p: Int) -> Bool {
            let u = Array(s.utf16); guard p + u.count <= n else { return false }
            for (k, c) in u.enumerated() where b[p + k] != c { return false }
            return true
        }
        func isIdentStart(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127 }
        func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        while i < n {
            let c = b[i]
            if c == 10 { lineStart = true; i += 1; continue }
            // Block comment
            if let bc = spec.blockComment, starts(bc.open, at: i) {
                var j = i + bc.open.utf16.count
                while j < n, !starts(bc.close, at: j) { j += 1 }
                j = min(n, j + bc.close.utf16.count)
                out.append((NSRange(location: i, length: j - i), .comment)); i = j; lineStart = false; continue
            }
            // Line comment
            if let lc = spec.lineComments.first(where: { starts($0, at: i) }) {
                _ = lc
                var j = i; while j < n, b[j] != 10 { j += 1 }
                out.append((NSRange(location: i, length: j - i), .comment)); i = j; continue
            }
            // Strings
            if let q = spec.stringQuotes.first(where: { $0.utf16.first == c }) {
                let qc = q.utf16.first!
                var j = i + 1
                if spec.tripleQuotes, i + 2 < n, b[i + 1] == qc, b[i + 2] == qc {
                    j = i + 3
                    while j < n, !(b[j] == qc && j + 2 < n + 1 && j + 2 <= n - 1 + 1 && starts(String(repeating: q, count: 3), at: j)) { j += 1 }
                    j = min(n, j + 3)
                } else {
                    while j < n, b[j] != qc, b[j] != 10 { if b[j] == 92 { j += 1 }; j += 1 }
                    j = min(n, j + 1)
                }
                let range = NSRange(location: i, length: j - i)
                // JSON/YAML: a quoted string followed by ':' is a key
                var k = j; while k < n, b[k] == 32 { k += 1 }
                let isKey = spec.keysBeforeColon && k < n && b[k] == 58
                out.append((range, isKey ? .key : .string)); i = j; lineStart = false; continue
            }
            // Numbers
            if (c >= 48 && c <= 57) || (c == 46 && i + 1 < n && b[i + 1] >= 48 && b[i + 1] <= 57) {
                var j = i + 1
                while j < n, (b[j] >= 48 && b[j] <= 57) || b[j] == 46 || b[j] == 95 || (b[j] >= 97 && b[j] <= 122) || (b[j] >= 65 && b[j] <= 90) { j += 1 }
                out.append((NSRange(location: i, length: j - i), .number)); i = j; lineStart = false; continue
            }
            // $variables
            if spec.variablesWithDollar, c == 36 {
                var j = i + 1
                if j < n, b[j] == 123 { while j < n, b[j] != 125 { j += 1 }; j = min(n, j + 1) }
                else { while j < n, isIdent(b[j]) { j += 1 } }
                if j > i + 1 { out.append((NSRange(location: i, length: j - i), .variable)); i = j; lineStart = false; continue }
            }
            // Identifiers / keywords / types / keys
            if isIdentStart(c) || (c == 64 && i + 1 < n && isIdentStart(b[i + 1])) {   // @attribute
                var j = i + 1
                while j < n, isIdent(b[j]) || b[j] == 45 && spec.keysBeforeColon { j += 1 }
                let word = String(utf16CodeUnits: Array(b[i..<j]), count: j - i)
                let cmp = spec.caseInsensitiveKeywords ? word.lowercased() : word
                var k = j; while k < n, b[k] == 32 { k += 1 }
                if c == 64 { out.append((NSRange(location: i, length: j - i), .attribute)) }
                else if spec.keysBeforeColon, lineStart || spec.keywords.isEmpty, k < n, b[k] == 58, !(k + 1 < n && b[k + 1] == 58) {
                    out.append((NSRange(location: i, length: j - i), .key))
                } else if spec.keywords.contains(cmp) { out.append((NSRange(location: i, length: j - i), .keyword)) }
                else if spec.types.contains(word) || (spec.capitalizedTypes && (c >= 65 && c <= 90)) { out.append((NSRange(location: i, length: j - i), .type)) }
                i = j; lineStart = false; continue
            }
            if c != 32 && c != 9 { lineStart = false }
            i += 1
        }
        return out
    }
}

/// Line-oriented: unified diffs.
public struct DiffHighlighter: CodeHighlighter {
    public init() {}
    public func tokens(in code: String) -> [(NSRange, CodeToken)] {
        var out: [(NSRange, CodeToken)] = []
        var loc = 0
        for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
            let len = line.utf16.count
            let r = NSRange(location: loc, length: len)
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { out.append((r, .meta)) }
            else if line.hasPrefix("@@") { out.append((r, .key)) }
            else if line.hasPrefix("+") { out.append((r, .added)) }
            else if line.hasPrefix("-") { out.append((r, .removed)) }
            loc += len + 1
        }
        return out
    }
}

/// Tags and attributes for HTML/XML.
public struct MarkupHighlighter: CodeHighlighter {
    public init() {}
    public func tokens(in code: String) -> [(NSRange, CodeToken)] {
        let b = Array(code.utf16); let n = b.count
        var out: [(NSRange, CodeToken)] = []
        var i = 0
        while i < n {
            if i + 3 < n, b[i] == 60, b[i+1] == 33, b[i+2] == 45, b[i+3] == 45 {   // <!--
                var j = i + 4
                while j + 2 < n, !(b[j] == 45 && b[j+1] == 45 && b[j+2] == 62) { j += 1 }
                j = min(n, j + 3)
                out.append((NSRange(location: i, length: j - i), .comment)); i = j; continue
            }
            if b[i] == 60 {   // <tag ... >
                var j = i + 1
                if j < n, b[j] == 47 { j += 1 }
                let nameStart = j
                while j < n, b[j] != 32 && b[j] != 62 && b[j] != 10 && b[j] != 47 { j += 1 }
                if j > nameStart { out.append((NSRange(location: i, length: j - i), .tag)) }
                // attributes until '>'
                while j < n, b[j] != 62 {
                    if b[j] == 34 || b[j] == 39 {
                        let q = b[j]; var k = j + 1
                        while k < n, b[k] != q { k += 1 }
                        k = min(n, k + 1)
                        out.append((NSRange(location: j, length: k - j), .string)); j = k; continue
                    }
                    if (b[j] >= 97 && b[j] <= 122) || (b[j] >= 65 && b[j] <= 90) {
                        var k = j
                        while k < n, (b[k] >= 97 && b[k] <= 122) || (b[k] >= 65 && b[k] <= 90) || b[k] == 45 || b[k] == 58 { k += 1 }
                        out.append((NSRange(location: j, length: k - j), .attribute)); j = k; continue
                    }
                    j += 1
                }
                if j < n { out.append((NSRange(location: j, length: 1), .tag)) }
                i = j + 1; continue
            }
            i += 1
        }
        return out
    }
}

public enum Highlighters {
    /// Highlighter for a fence info string (first word, case-insensitive), or nil.
    public static func highlighter(for info: String) -> CodeHighlighter? {
        let lang = info.split(whereSeparator: { $0 == " " || $0 == "{" }).first.map { String($0).lowercased() } ?? ""
        switch lang {
        case "swift": return GenericHighlighter(swift)
        case "python", "py": return GenericHighlighter(python)
        case "javascript", "js", "jsx", "typescript", "ts", "tsx": return GenericHighlighter(javascript)
        case "json", "jsonc": return GenericHighlighter(json)
        case "yaml", "yml": return GenericHighlighter(yaml)
        case "toml": return GenericHighlighter(toml)
        case "bash", "sh", "zsh", "shell", "console", "fish": return GenericHighlighter(shell)
        case "sql", "psql", "mysql", "sqlite": return GenericHighlighter(sql)
        case "go", "golang": return GenericHighlighter(go)
        case "rust", "rs": return GenericHighlighter(rust)
        case "ruby", "rb": return GenericHighlighter(ruby)
        case "java", "kotlin", "kt", "c", "cpp", "c++", "h", "objc", "objective-c", "csharp", "cs": return GenericHighlighter(cLike)
        case "css", "scss": return GenericHighlighter(css)
        case "html", "xml", "svg", "plist": return MarkupHighlighter()
        case "diff", "patch": return DiffHighlighter()
        default: return nil
        }
    }

    static let cKeywords: Set<String> = ["if", "else", "for", "while", "do", "return", "break", "continue", "switch", "case", "default", "class", "struct", "enum", "interface", "new", "this", "static", "public", "private", "protected", "void", "const", "try", "catch", "finally", "throw", "throws", "import", "package", "extends", "implements", "final", "abstract", "super", "null", "true", "false", "int", "long", "double", "float", "char", "bool", "boolean", "var", "val", "fun", "let", "override", "namespace", "using", "typedef", "template", "virtual", "sizeof", "goto", "auto", "delete", "nullptr"]

    static let swift = LanguageSpec(
        keywords: ["func", "let", "var", "if", "else", "guard", "return", "for", "in", "while", "repeat", "switch", "case", "default", "break", "continue", "struct", "class", "enum", "protocol", "extension", "import", "public", "private", "fileprivate", "internal", "open", "static", "final", "override", "init", "deinit", "self", "Self", "super", "nil", "true", "false", "throws", "throw", "try", "catch", "async", "await", "actor", "some", "any", "where", "as", "is", "inout", "mutating", "nonisolated", "defer", "typealias", "associatedtype", "subscript", "lazy", "weak", "unowned", "convenience", "required", "indirect", "rethrows", "fallthrough", "do", "operator", "precedencegroup"],
        lineComments: ["//"], blockComment: ("/*", "*/"), capitalizedTypes: true)
    static let python = LanguageSpec(
        keywords: ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "try", "except", "finally", "raise", "with", "lambda", "pass", "break", "continue", "and", "or", "not", "in", "is", "None", "True", "False", "yield", "async", "await", "global", "nonlocal", "del", "assert", "self"],
        lineComments: ["#"], tripleQuotes: true, capitalizedTypes: true)
    static let javascript = LanguageSpec(
        keywords: cKeywords.union(["function", "const", "let", "var", "of", "in", "typeof", "instanceof", "export", "from", "async", "await", "yield", "undefined", "type", "interface", "readonly", "declare", "module", "as", "keyof", "enum", "implements", "get", "set", "constructor", "arguments"]),
        lineComments: ["//"], blockComment: ("/*", "*/"), stringQuotes: ["\"", "'", "`"], capitalizedTypes: true)
    static let json = LanguageSpec(keywords: ["true", "false", "null"], keysBeforeColon: true)
    static let yaml = LanguageSpec(keywords: ["true", "false", "null", "yes", "no", "~"], lineComments: ["#"], keysBeforeColon: true)
    static let toml = LanguageSpec(keywords: ["true", "false"], lineComments: ["#"])
    static let shell = LanguageSpec(
        keywords: ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "return", "local", "export", "set", "unset", "echo", "exit", "source", "alias", "readonly", "declare", "shift", "trap", "cd", "sudo"],
        lineComments: ["#"], stringQuotes: ["\"", "'", "`"], variablesWithDollar: true)
    static let sql = LanguageSpec(
        keywords: ["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add", "column", "primary", "key", "foreign", "references", "join", "inner", "left", "right", "outer", "on", "group", "by", "order", "having", "limit", "offset", "as", "and", "or", "not", "null", "is", "in", "like", "between", "distinct", "count", "sum", "avg", "min", "max", "union", "all", "exists", "case", "when", "then", "else", "end", "index", "view", "with", "begin", "commit", "rollback", "transaction", "int", "integer", "text", "varchar", "boolean", "date", "timestamp", "default", "unique", "constraint", "returning", "true", "false", "asc", "desc"],
        lineComments: ["--"], blockComment: ("/*", "*/"), stringQuotes: ["'"], caseInsensitiveKeywords: true)
    static let go = LanguageSpec(
        keywords: ["func", "package", "import", "var", "const", "type", "struct", "interface", "map", "chan", "go", "defer", "if", "else", "for", "range", "switch", "case", "default", "return", "break", "continue", "select", "fallthrough", "goto", "nil", "true", "false", "make", "new", "len", "cap", "append", "error", "string", "int", "int64", "bool", "byte", "float64", "uint"],
        lineComments: ["//"], blockComment: ("/*", "*/"), stringQuotes: ["\"", "'", "`"], capitalizedTypes: true)
    static let rust = LanguageSpec(
        keywords: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "for", "in", "while", "loop", "if", "else", "match", "return", "use", "mod", "crate", "self", "Self", "super", "as", "where", "type", "const", "static", "ref", "move", "async", "await", "dyn", "unsafe", "true", "false", "break", "continue", "Some", "None", "Ok", "Err"],
        lineComments: ["//"], blockComment: ("/*", "*/"), capitalizedTypes: true)
    static let ruby = LanguageSpec(
        keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "until", "for", "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "require", "include", "extend", "attr_accessor", "attr_reader", "self", "nil", "true", "false", "and", "or", "not", "then", "case", "when", "puts", "lambda", "proc"],
        lineComments: ["#"], capitalizedTypes: true)
    static let cLike = LanguageSpec(keywords: cKeywords, lineComments: ["//"], blockComment: ("/*", "*/"), capitalizedTypes: true)
    static let css = LanguageSpec(keywords: ["important", "px", "em", "rem", "auto", "none", "inherit", "solid", "flex", "grid", "block", "inline", "absolute", "relative"], blockComment: ("/*", "*/"), keysBeforeColon: true)
}

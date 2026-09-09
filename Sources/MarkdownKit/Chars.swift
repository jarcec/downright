import Foundation

/// UTF-16 code unit constants and classification helpers. The parser works on a
/// `[UInt16]` buffer for O(1) random access with offsets that are already `NSRange`
/// offsets (plan decision D1).
enum C {
    static let tab: UInt16 = 9
    static let newline: UInt16 = 10
    static let space: UInt16 = 32
    static let bang: UInt16 = 33        // !
    static let dquote: UInt16 = 34      // "
    static let hash: UInt16 = 35        // #
    static let squote: UInt16 = 39      // '
    static let lparen: UInt16 = 40      // (
    static let rparen: UInt16 = 41      // )
    static let star: UInt16 = 42        // *
    static let plus: UInt16 = 43        // +
    static let minus: UInt16 = 45       // -
    static let dot: UInt16 = 46         // .
    static let slash: UInt16 = 47       // /
    static let colon: UInt16 = 58       // :
    static let lt: UInt16 = 60          // <
    static let eq: UInt16 = 61          // =
    static let gt: UInt16 = 62          // >
    static let question: UInt16 = 63    // ?
    static let lbracket: UInt16 = 91    // [
    static let backslash: UInt16 = 92   // \
    static let rbracket: UInt16 = 93    // ]
    static let underscore: UInt16 = 95  // _
    static let backtick: UInt16 = 96    // `
    static let tilde: UInt16 = 126      // ~
    static let pipe: UInt16 = 124       // |
    static let x: UInt16 = 120
    static let X: UInt16 = 88

    static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    static func isSpaceOrTab(_ c: UInt16) -> Bool { c == space || c == tab }
    static func isAsciiLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    static func isAlnum(_ c: UInt16) -> Bool { isDigit(c) || isAsciiLetter(c) }

    static func isWhitespace(_ c: UInt16) -> Bool {
        c == space || c == tab || c == newline || c == 12 || c == 13 || c == 0xA0
            || c == 0x2000 || c == 0x2001 || c == 0x2002 || c == 0x2003 || c == 0x2004
            || c == 0x2005 || c == 0x2006 || c == 0x2007 || c == 0x2008 || c == 0x2009
            || c == 0x200A || c == 0x202F || c == 0x205F || c == 0x3000
    }

    static func isAsciiPunct(_ c: UInt16) -> Bool {
        (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126)
    }

    static func isPunctuation(_ c: UInt16) -> Bool {
        if isAsciiPunct(c) { return true }
        guard let scalar = Unicode.Scalar(UInt32(c)) else { return false }
        return scalar.properties.generalCategory.isPunctuationOrSymbol
    }
}

extension Unicode.GeneralCategory {
    var isPunctuationOrSymbol: Bool {
        switch self {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}

public extension NSRange {
    /// `location + length`. Public so the editor module shares one spelling.
    var end: Int { location + length }
    init(_ start: Int, to end: Int) { self.init(location: start, length: end - start) }
}

extension Array where Element == UInt16 {
    func string(_ r: NSRange) -> String {
        guard r.length > 0, r.location >= 0, r.end <= count else { return "" }
        return String(utf16CodeUnits: Array(self[r.location..<r.end]), count: r.length)
    }
}

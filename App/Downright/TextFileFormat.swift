import Foundation

/// Byte-level facts about a text file that must survive a round trip (TRD §8):
/// encoding, BOM, dominant line ending. Text is normalised to `\n` in memory.
struct TextFileFormat: Equatable {
    enum LineEnding: String { case lf = "\n", crlf = "\r\n", cr = "\r" }

    var encoding: String.Encoding = .utf8
    var hasBOM = false
    var lineEnding: LineEnding = .lf

    struct DecodeError: LocalizedError {
        var errorDescription: String? { "The file is not UTF-8 or UTF-16 text." }
    }

    static func decode(_ data: Data) throws -> (String, TextFileFormat) {
        var format = TextFileFormat()
        var body = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            format.hasBOM = true; body = data.dropFirst(3)
        } else if data.starts(with: [0xFF, 0xFE]) {
            format.encoding = .utf16LittleEndian; format.hasBOM = true; body = data.dropFirst(2)
        } else if data.starts(with: [0xFE, 0xFF]) {
            format.encoding = .utf16BigEndian; format.hasBOM = true; body = data.dropFirst(2)
        }
        guard let raw = String(data: body, encoding: format.encoding) else { throw DecodeError() }

        var crlf = 0, lf = 0, cr = 0
        var prevCR = false
        for u in raw.utf16 {
            if u == 13 { prevCR = true; continue }
            if u == 10 { if prevCR { crlf += 1 } else { lf += 1 } } else if prevCR { cr += 1 }
            prevCR = false
        }
        if prevCR { cr += 1 }
        if crlf > lf && crlf >= cr { format.lineEnding = .crlf }
        else if cr > lf && cr > crlf { format.lineEnding = .cr }
        else { format.lineEnding = .lf }

        let normalised = (crlf + cr) == 0 ? raw : raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return (normalised, format)
    }

    func encode(_ text: String) -> Data {
        let out = lineEnding == .lf ? text : text.replacingOccurrences(of: "\n", with: lineEnding.rawValue)
        var data = Data()
        if hasBOM {
            switch encoding {
            case .utf8: data.append(contentsOf: [0xEF, 0xBB, 0xBF])
            case .utf16LittleEndian: data.append(contentsOf: [0xFF, 0xFE])
            case .utf16BigEndian: data.append(contentsOf: [0xFE, 0xFF])
            default: break
            }
        }
        data.append(out.data(using: encoding) ?? Data(out.utf8))
        return data
    }
}

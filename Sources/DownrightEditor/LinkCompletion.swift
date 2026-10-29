import AppKit
import MarkdownKit

/// Destinations offered while a link is typed: after `](` the files next to the
/// document (a folder's `/` opens it), after `#` this document's headings, and after
/// `notes.md#` the headings in that file. It is the text view's own completion list
/// (⌥⎋ brings it back), so it is keyboard-driven and nothing is inserted until one is
/// chosen.
extension EditorController {
    /// The destination being typed, from just after `](` (or `![alt](`) to `offset`, if
    /// `offset` is in one: nothing between them but what a destination can hold.
    func linkDestination(endingAt offset: Int) -> NSRange? {
        let s = textStorage.string as NSString
        guard offset <= s.length else { return nil }
        let lineStart = lines.lineStarts[lines.line(containing: offset)]
        var p = offset
        while p > lineStart {
            let c = s.character(at: p - 1)
            if c == 40 { break }   // (
            if c == 32 || c == 9 || c == 41 || c == 60 || c == 62 || c == 34 || c == 91 || c == 93 { return nil }   // space tab ) < > " [ ]
            p -= 1
        }
        guard p > lineStart + 1, s.character(at: p - 1) == 40, s.character(at: p - 2) == 93 else { return nil }   // ](
        if let leaf = document.path(containing: max(lineStart, offset - 1)).last {
            switch leaf.kind {
            case .fencedCode, .indentedCode, .htmlBlock, .frontmatter: return nil
            default: break
            }
            let inCode = Document.inlines(in: leaf, intersecting: NSRange(location: p - 1, length: 1)).contains {
                if case .code = $0.kind { return true } else { return false }
            }
            if inCode { return nil }
        }
        return NSRange(p, to: offset)
    }

    /// Full destinations that start with `partial`, best first.
    func linkCompletions(for partial: String) -> [String] {
        if let hash = partial.firstIndex(of: "#") {
            let file = String(partial[..<hash])
            let fragment = String(partial[partial.index(after: hash)...]).lowercased()
            let anchors: [HeadingAnchor]
            if file.isEmpty {
                anchors = engine.anchors
            } else {
                guard let url = ImageLoader.resolve(file.removingPercentEncoding ?? file, baseURL: baseURL),
                      LinkTargets.isMarkdown(url), let theirs = LinkTargets.shared.anchors(of: url) else { return [] }
                anchors = theirs
            }
            var seen = Set<String>()
            return anchors.filter { a in
                fragment.isEmpty || a.slug.hasPrefix(fragment) || a.title.lowercased().contains(fragment.replacingOccurrences(of: "-", with: " "))
            }.compactMap { a in seen.insert(a.slug).inserted ? "\(file)#\(a.slug)" : nil }
        }
        guard let baseURL, baseURL.isFileURL else { return [] }
        let slash = partial.lastIndex(of: "/").map { partial.index(after: $0) } ?? partial.startIndex
        let folder = String(partial[..<slash])
        let prefix = (String(partial[slash...]).removingPercentEncoding ?? String(partial[slash...])).lowercased()
        let directory = baseURL.deletingLastPathComponent().appendingPathComponent(folder.removingPercentEncoding ?? folder, isDirectory: true)
        let own = baseURL.standardizedFileURL.path
        return LinkTargets.shared.entries(of: directory).filter { e in
            e.name.lowercased().hasPrefix(prefix) && directory.appendingPathComponent(e.name).standardizedFileURL.path != own
        }.prefix(200).map { e in
            folder + Self.destinationEncoded(e.name) + (e.isDirectory ? "/" : "")
        }
    }

    /// A file name as a destination: spaces and angle brackets would end it, so they go
    /// percent-encoded, the way GitHub writes them.
    static func destinationEncoded(_ name: String) -> String {
        name.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E")
    }
}

extension MarkdownTextView {
    /// The partial destination, inside a link; the word, anywhere else.
    public override var rangeForUserCompletion: NSRange {
        if selectedRange().length == 0, let r = controller?.linkDestination(endingAt: selectedRange().location) { return r }
        return super.rangeForUserCompletion
    }

    public override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard let controller, let r = controller.linkDestination(endingAt: charRange.end), r == charRange else {
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }
        index.pointee = -1   // nothing chosen until the arrow keys choose it
        return controller.linkCompletions(for: (string as NSString).substring(with: charRange))
    }

    /// Typing `(` after `]`, or a `#` or `/` in a destination, brings up the list when
    /// there is something to offer.
    func offerLinkCompletion(after typed: String) {
        guard typed == "(" || typed == "#" || typed == "/", selectedRange().length == 0, let controller,
              let r = controller.linkDestination(endingAt: selectedRange().location),
              !controller.linkCompletions(for: (string as NSString).substring(with: r)).isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.complete(nil) }
    }

    /// A folder chosen from the list opens it: its own entries come up next.
    public override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        guard flag, movement != NSTextMovement.cancel.rawValue, word.hasSuffix("/"),
              controller?.linkDestination(endingAt: selectedRange().location) != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.complete(nil) }
    }
}

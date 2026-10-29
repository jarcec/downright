import AppKit
import MarkdownKit

/// What a link can point at: the files near a document, and the headings inside the
/// Markdown ones. Used to mark links that lead nowhere and to offer destinations while
/// one is typed. Another file's headings are read once and kept until it changes on disk.
@MainActor
public final class LinkTargets {
    public static let shared = LinkTargets()

    private var anchors: [String: (modified: Date?, anchors: [HeadingAnchor])] = [:]

    public init() {}

    /// Extensions read as Markdown (their anchors can be checked and offered).
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"]

    public static func isMarkdown(_ url: URL) -> Bool { markdownExtensions.contains(url.pathExtension.lowercased()) }

    public func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The headings of the Markdown file at `url`; nil when it cannot be read.
    public func anchors(of url: URL) -> [HeadingAnchor]? {
        let path = url.standardizedFileURL.path
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        if let hit = anchors[path], hit.modified == modified { return hit.anchors }
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
            anchors[path] = nil
            return nil
        }
        let found = MarkdownParser.parse(text).headingAnchors()
        if anchors.count > 200 { anchors.removeAll() }
        anchors[path] = (modified, found)
        return found
    }

    /// What is in `directory`, hidden entries left out: Markdown files first, then other
    /// files, then folders, each by name.
    public func entries(of directory: URL) -> [(name: String, isDirectory: Bool)] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let entries = items.map { url in (name: url.lastPathComponent, isDirectory: (try? url.resourceValues(forKeys: Set(keys)).isDirectory) == true) }
        func rank(_ e: (name: String, isDirectory: Bool)) -> Int {
            e.isDirectory ? 2 : Self.isMarkdown(URL(fileURLWithPath: e.name)) ? 0 : 1
        }
        return entries.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Why `url` (a link's resolved target) leads nowhere, or nil when it leads somewhere
    /// or cannot be checked. `anchors` are this document's own; an anchor is compared
    /// slugged, the way following it matches (`#Setup Notes` finds `#setup-notes`).
    public func problem(with url: URL, anchors own: [HeadingAnchor]) -> String? {
        func wanted(_ fragment: String) -> String { Document.slug(fragment.removingPercentEncoding ?? fragment) }
        if url.scheme == nil {
            guard let fragment = url.fragment, !fragment.isEmpty else { return nil }
            return own.contains { $0.slug == wanted(fragment) } ? nil : "No heading “#\(fragment)” in this document"
        }
        guard url.isFileURL else { return nil }
        let file = URL(fileURLWithPath: url.path)
        guard exists(file) else { return "Nothing at \(file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))" }
        if let fragment = url.fragment, !fragment.isEmpty, Self.isMarkdown(file), let theirs = anchors(of: file),
           !theirs.contains(where: { $0.slug == wanted(fragment) }) {
            return "No heading “#\(fragment)” in \(file.lastPathComponent)"
        }
        return nil
    }
}

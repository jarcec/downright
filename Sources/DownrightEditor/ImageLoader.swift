import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Loads and caches the bitmaps behind `![alt](src)`. Decoding happens off the main
/// actor and is capped in pixels, so a photo straight off a camera costs a thumbnail,
/// not its full frame. Local files load on sight; remote images only when allowed
/// (opening a document should not phone home, PRD §7.3).
@MainActor
public final class ImageLoader {
    public enum State: Equatable {
        case loaded(NSImage)
        case loading
        case failed
        /// An `http(s)` image with remote loading off.
        case remote
    }

    /// Fetch `http(s)` images. Off by default; a setting turns it on.
    public var loadsRemoteImages = false {
        didSet {
            guard loadsRemoteImages != oldValue else { return }
            // Blocked placeholders become loads (or the reverse) on the next build.
            for (url, state) in cache where state == .remote || (!loadsRemoteImages && !url.isFileURL) { cache[url] = nil }
            onReset?()
        }
    }
    /// Called on the main actor when an image finishes loading, either way.
    public var onLoad: ((URL) -> Void)?
    /// Called when the cache is dropped wholesale (a setting flipped); every image
    /// paragraph should rebuild.
    public var onReset: (() -> Void)?

    /// Longest side of a decoded bitmap, in pixels: twice a wide column on a Retina display.
    nonisolated public static let maxPixelSize = 2400

    private var cache: [URL: State] = [:]
    /// Modification dates of the files behind loaded images; a changed file reloads.
    private var dates: [URL: Date] = [:]

    public init() {}

    // MARK: - Resolution

    /// The URL a destination names, or nil when it cannot name one (a relative path in an
    /// untitled document). Relative paths resolve against the document's directory;
    /// absolute paths, `~`, and `file:` URLs stand alone. Percent-escapes are undone so
    /// `my%20image.png` finds "my image.png".
    public static func resolve(_ destination: String, baseURL: URL?) -> URL? {
        let dest = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dest.isEmpty else { return nil }
        if let u = URL(string: dest), let scheme = u.scheme?.lowercased() {
            switch scheme {
            case "file": return u.standardizedFileURL
            case "http", "https": return u
            default: break
            }
            // A Windows drive letter or a bare word with a colon is not a scheme we know;
            // fall through and treat it as a path.
            if scheme.count > 1 { return nil }
        }
        let path = dest.removingPercentEncoding ?? dest
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }
        guard let base = baseURL, base.isFileURL else { return nil }
        return URL(fileURLWithPath: path, relativeTo: base.deletingLastPathComponent()).standardizedFileURL
    }

    // MARK: - Cache

    /// The image for `url` if it is ready; otherwise the state it is in. Starts a load
    /// the first time a URL is asked for, and again when its file changed on disk.
    public func image(for url: URL) -> State {
        if url.isFileURL {
            let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            if let hit = cache[url], hit == .loading || dates[url] == date { return hit }
            dates[url] = date
        } else {
            if !loadsRemoteImages { cache[url] = .remote; return .remote }
            if let hit = cache[url] { return hit }
        }
        cache[url] = .loading
        Task.detached(priority: .userInitiated) { [weak self] in
            let image = Self.decode(url)
            await MainActor.run {
                guard let self, self.cache[url] == .loading else { return }
                self.cache[url] = image.map { .loaded($0) } ?? .failed
                self.onLoad?(url)
            }
        }
        return .loading
    }

    /// Forget everything; every image loads afresh when next asked for.
    public func reset() {
        cache.removeAll()
        dates.removeAll()
        onReset?()
    }

    // MARK: - Decoding

    /// Decode `url` to an image whose point size honours the file's DPI (a 2× screenshot
    /// shows at half its pixel size) and whose bitmap is at most `maxPixelSize` on a
    /// side. Synchronous: callers run it off the main actor, or accept the wait (export).
    nonisolated public static func decode(_ url: URL, maxPixelSize: Int = ImageLoader.maxPixelSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return url.isFileURL ? NSImage(contentsOf: url) : nil   // PDF, SVG via NSImage
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Double, let ph = props[kCGImagePropertyPixelHeight] as? Double,
              pw > 0, ph > 0 else {
            return url.isFileURL ? NSImage(contentsOf: url) : nil
        }
        let dpi = (props[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        var points = CGSize(width: pw * 72 / dpi, height: ph * 72 / dpi)
        // EXIF orientation 5–8 swap width and height once applied.
        if let o = props[kCGImagePropertyOrientation] as? UInt32, o >= 5 { points = CGSize(width: points.height, height: points.width) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCache: false,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return url.isFileURL ? NSImage(contentsOf: url) : nil
        }
        return NSImage(cgImage: cg, size: points)
    }
}

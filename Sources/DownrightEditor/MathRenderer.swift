import AppKit
import JavaScriptCore

/// Typesets TeX (`$…$`, `$$…$$`, ```` ```math ````) with MathJax, the engine GitHub uses,
/// bundled (`mathjax-tex-svg.js`, MathJax 3.2.2, Apache 2.0; see `tools/build-mathjax.sh`).
/// It runs in a plain JavaScriptCore context, with no DOM, no WebKit and no network, and
/// its SVG output is glyphs drawn as paths, so AppKit draws it directly and it stays
/// sharp at any zoom. Loading takes about 50 ms, once; a formula takes a few
/// milliseconds, so it is done synchronously, while the line is laid out.
@MainActor
public final class MathRenderer {
    public static let shared = MathRenderer()

    public struct Formula {
        public var image: NSImage
        /// How far the formula reaches below the text's baseline, in points.
        public var descent: CGFloat
    }

    public enum Result {
        case rendered(Formula)
        /// TeX's own message ("Missing close brace"), for the tooltip.
        case failed(String)
    }

    private var context: JSContext?
    private var typeset: JSValue?
    private var loadFailed = false
    /// MathJax's output per formula, before colour and size: `display\nsource` → SVG or error.
    private var svgs: [String: Swift.Result<String, TeXError>] = [:]
    /// Finished pictures, per formula, colour and size.
    private var images: [String: Result] = [:]
    private let limit = 500

    struct TeXError: Error { var message: String }

    public init() {}

    /// Whether an info string (```` ```math ````, or the `math` a `$$` fence gets) names TeX.
    public nonisolated static func isMath(info: String) -> Bool {
        info.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first?.lowercased() == "math"
    }

    /// The formula drawn in `color` (resolved, sRGB) at a size matching text of `fontSize`.
    public func formula(_ tex: String, display: Bool, color: NSColor, fontSize: CGFloat) -> Result {
        let hex = String((color.usingColorSpace(.sRGB) ?? color).hexString.prefix(7))
        let key = "\(display ? 1 : 0)\(hex)\(fontSize)\n\(tex)"
        if let hit = images[key] { return hit }
        if images.count >= limit { images.removeAll() }
        let result: Result
        switch svg(tex, display: display) {
        case .failure(let e): result = .failed(e.message)
        case .success(let svg): result = Self.picture(svg, color: hex, fontSize: fontSize).map { .rendered($0) } ?? .failed("The formula came out empty.")
        }
        images[key] = result
        return result
    }

    private func svg(_ tex: String, display: Bool) -> Swift.Result<String, TeXError> {
        let key = "\(display ? 1 : 0)\n\(tex)"
        if let hit = svgs[key] { return hit }
        if svgs.count >= limit { svgs.removeAll() }
        let out: Swift.Result<String, TeXError>
        if let typeset = load(), let value = typeset.call(withArguments: [tex, display]) {
            if let svg = value.objectForKeyedSubscript("svg"), svg.isString, let s = svg.toString() {
                out = .success(s)
            } else {
                let message = value.objectForKeyedSubscript("error")?.toString() ?? "TeX could not read this."
                out = .failure(TeXError(message: message))
            }
        } else {
            out = .failure(TeXError(message: "MathJax is missing from this build."))
        }
        svgs[key] = out
        return out
    }

    private func load() -> JSValue? {
        if let typeset { return typeset }
        guard !loadFailed, let url = Bundle.module.url(forResource: "mathjax-tex-svg", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8), let context = JSContext() else {
            loadFailed = true
            return nil
        }
        context.evaluateScript(script)
        guard let fn = context.objectForKeyedSubscript("texToSVG"), !fn.isUndefined else {
            loadFailed = true
            return nil
        }
        self.context = context
        typeset = fn
        return fn
    }

    /// MathJax measures in thousandths of an em of its TeX font, whose x-height is 0.442
    /// em. Scaling so that matches the text's x-height is what MathJax does on a web page
    /// (`matchFontHeight`), so letters in a formula sit level with the words around it.
    static func scale(forFontSize size: CGFloat) -> CGFloat {
        let xHeight = NSFont.systemFont(ofSize: size).xHeight
        return min(1.25, max(1, xHeight / (0.442 * size)))
    }

    /// The SVG as a picture: coloured, sized from its viewBox, with its depth below the
    /// baseline.
    static func picture(_ svg: String, color hex: String, fontSize: CGFloat) -> Formula? {
        guard let box = viewBox(svg), box.width > 0, box.height > 0 else { return nil }
        let em = fontSize * scale(forFontSize: fontSize) / 1000
        let size = NSSize(width: ceil(box.width * em * 2) / 2, height: ceil(box.height * em * 2) / 2)
        let colored = svg.replacingOccurrences(of: "currentColor", with: hex)
        guard let image = NSImage(data: Data(colored.utf8)) else { return nil }
        image.size = size
        return Formula(image: image, descent: max(0, (box.minY + box.height) * em))
    }

    /// `viewBox="minX minY width height"` of the outer `<svg>`.
    static func viewBox(_ svg: String) -> CGRect? {
        guard let start = svg.range(of: "viewBox=\""), let end = svg[start.upperBound...].firstIndex(of: "\"") else { return nil }
        let v = svg[start.upperBound..<end].split(separator: " ").compactMap { Double($0) }
        guard v.count == 4 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
}

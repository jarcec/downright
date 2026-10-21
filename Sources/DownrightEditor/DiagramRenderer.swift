import AppKit
import WebKit

/// Renders ```` ```mermaid ```` blocks to images and caches them, the way `ImageLoader`
/// does bitmaps. The drawing is Mermaid's own, done in a hidden WebKit view shared by
/// every document (`MermaidWebView`); a diagram is keyed by its source and the colours it
/// was drawn in, so typing elsewhere, scrolling, or flipping back to a theme never
/// renders it again.
@MainActor
public final class DiagramRenderer {
    public enum State: Equatable {
        case rendered(NSImage)
        case rendering
        /// Mermaid could not draw it; its message, for the placeholder's tooltip.
        case failed(String)
    }

    /// Called on the main actor when a diagram finishes, either way, with its key.
    public var onRender: ((String) -> Void)?
    /// The appearance the editor's dynamic colours resolve in (the text view's).
    public var appearance: NSAppearance?

    private var cache: [String: State] = [:]
    /// Rendered diagrams kept; beyond it the cache starts over (sources edited many times
    /// leave a trail of versions nobody will ask for again).
    private let limit = 200

    public init() {}

    /// The diagram for `source` in `theme`'s colours if it is ready; otherwise the state it
    /// is in. Starts a render the first time it is asked for. `appearance` overrides the
    /// editor's (rich-text export draws on paper).
    public func diagram(for source: String, theme: Theme, appearance: NSAppearance? = nil) -> (key: String, state: State) {
        let style = MermaidStyle(theme: theme, appearance: appearance ?? self.appearance)
        let key = style.key + "\n" + source
        if let hit = cache[key] { return (key, hit) }
        if cache.count >= limit { cache = cache.filter { $0.value == .rendering } }
        cache[key] = .rendering
        Task { [weak self] in
            let state: State
            do { state = .rendered(try await MermaidWebView.shared.render(source, style: style)) }
            catch { state = .failed(MermaidWebView.message(for: error)) }
            guard let self, self.cache[key] == .rendering else { return }
            self.cache[key] = state
            self.onRender?(key)
        }
        return (key, .rendering)
    }

    /// Whether an info string (```` ```mermaid ````) names a diagram this renders.
    public nonisolated static func isDiagram(info: String) -> Bool {
        info.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "{" }).first?.lowercased() == "mermaid"
    }
}

/// Mermaid's configuration for one theme: its `base` theme with the editor's colours and
/// type, so a diagram reads as part of the page rather than Mermaid's stock blue.
struct MermaidStyle: Sendable {
    /// `mermaid.initialize` options, as JSON.
    let config: String
    /// Page colour behind the diagram (the snapshot is opaque).
    let background: String
    var key: String { config }

    init(theme: Theme, appearance: NSAppearance?) {
        var c: (bg: String, card: String, text: String, secondary: String, note: String, dark: Bool) = ("", "", "", "", "", false)
        (appearance ?? NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
            func hex(_ color: NSColor) -> String { String(color.hexString.prefix(7)) }   // drop the alpha
            let bg = theme.backgroundColor.usingColorSpace(.sRGB) ?? .white
            c = (hex(theme.backgroundColor), hex(theme.codeBlockBackground), hex(theme.textColor), hex(theme.secondaryColor),
                 hex(theme.codeBackground), 0.299 * bg.redComponent + 0.587 * bg.greenComponent + 0.114 * bg.blueComponent < 0.5)
        }
        background = c.bg
        let variables: [String: Any] = [
            "darkMode": c.dark, "background": c.bg, "fontFamily": "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif",
            "fontSize": "\(Int(theme.bodySize.rounded()))px",
            "primaryColor": c.card, "primaryBorderColor": c.secondary, "primaryTextColor": c.text,
            "secondaryColor": c.card, "secondaryBorderColor": c.secondary, "secondaryTextColor": c.text,
            "tertiaryColor": c.bg, "tertiaryBorderColor": c.secondary, "tertiaryTextColor": c.text,
            "mainBkg": c.card, "nodeBorder": c.secondary, "clusterBkg": c.bg, "clusterBorder": c.secondary,
            "lineColor": c.secondary, "textColor": c.text, "titleColor": c.text, "edgeLabelBackground": c.bg,
            "actorBkg": c.card, "actorBorder": c.secondary, "actorTextColor": c.text, "actorLineColor": c.secondary,
            "signalColor": c.secondary, "signalTextColor": c.text, "labelBoxBkgColor": c.card, "labelBoxBorderColor": c.secondary,
            "labelTextColor": c.text, "loopTextColor": c.text, "noteBkgColor": c.note, "noteBorderColor": c.secondary,
            "noteTextColor": c.text, "activationBkgColor": c.card, "activationBorderColor": c.secondary,
        ]
        let options: [String: Any] = [
            "startOnLoad": false, "securityLevel": "strict", "theme": "base", "themeVariables": variables,
            "fontFamily": variables["fontFamily"]!,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys])) ?? Data("{}".utf8)
        config = String(decoding: data, as: UTF8.self)
    }
}

/// The hidden WebKit view that runs Mermaid. Never on screen and never online: the page is
/// built from the bundled script under a policy that allows no network. Created on the
/// first diagram (about 0.4 s), then about 10 ms a diagram. Renders one at a time, since
/// each resizes the view to its diagram before the snapshot — WebKit draws nothing
/// outside the view's bounds.
@MainActor
final class MermaidWebView: NSObject, WKNavigationDelegate {
    static let shared = MermaidWebView()

    enum Failure: Error {
        case missingScript
        case timedOut
        case noImage
    }

    private var web: WKWebView?
    private var loaded: CheckedContinuation<Void, Error>?
    /// The job before this one; each waits for it, so renders run in order, one at a time.
    private var tail: Task<Void, Never>?
    private var counter = 0
    /// A diagram that takes longer than this is abandoned and the view rebuilt, so one
    /// pathological source cannot stall every diagram after it.
    private let timeout: Duration = .seconds(10)

    func render(_ source: String, style: MermaidStyle) async throws -> NSImage {
        let previous = tail
        let job = Task { @MainActor in
            _ = await previous?.value
            return try await self.renderNow(source, style: style)
        }
        tail = Task { _ = try? await job.value }
        return try await job.value
    }

    /// Draw one diagram, or give up after `timeout`: a hung script call cannot be
    /// cancelled, so the watchdog ends the wait itself and throws the view away.
    private func renderNow(_ source: String, style: MermaidStyle) async throws -> NSImage {
        let web = try await view()
        counter += 1
        let id = counter
        let race = Race()
        return try await withCheckedThrowingContinuation { continuation in
            race.continuation = continuation
            race.watchdog = Task { @MainActor in
                try? await Task.sleep(for: self.timeout)
                guard !Task.isCancelled, race.continuation != nil else { return }
                self.tearDown()
                race.finish(.failure(Failure.timedOut))
            }
            Task { @MainActor in
                do { race.finish(.success(try await Self.draw(source, style: style, id: id, in: web))) }
                catch { race.finish(.failure(error)) }
            }
        }
    }

    /// The first of the drawing and the watchdog to finish resolves the render.
    private final class Race {
        var continuation: CheckedContinuation<NSImage, Error>?
        var watchdog: Task<Void, Never>?
        func finish(_ result: Result<NSImage, Error>) {
            watchdog?.cancel()
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private static func draw(_ source: String, style: MermaidStyle, id: Int, in web: WKWebView) async throws -> NSImage {
        let box = try await web.callAsyncJavaScript("""
            mermaid.initialize(JSON.parse(config));
            document.body.style.background = background;
            const { svg } = await mermaid.render('diagram' + id, source);
            const out = document.getElementById('out');
            out.innerHTML = svg;
            const e = out.querySelector('svg'), vb = e.viewBox.baseVal;
            e.style.maxWidth = 'none';
            e.setAttribute('width', vb.width);
            e.setAttribute('height', vb.height);
            const r = e.getBoundingClientRect();
            return [Math.ceil(r.width), Math.ceil(r.height)];
            """, arguments: ["config": style.config, "background": style.background, "source": source, "id": id],
            contentWorld: .page) as? [Double]
        guard let box, box.count == 2, box[0] >= 1, box[1] >= 1 else { throw Failure.noImage }
        let size = NSSize(width: box[0], height: box[1])
        web.frame.size = NSSize(width: max(800, size.width), height: max(600, size.height))
        let snap = WKSnapshotConfiguration()
        snap.rect = NSRect(origin: .zero, size: size)
        let image = try await web.takeSnapshot(configuration: snap)
        image.size = size
        return image
    }

    /// The loaded view, built and loaded on first use.
    private func view() async throws -> WKWebView {
        if let web { return web }
        guard let url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.missingScript }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.navigationDelegate = self
        let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:">
            <style>html, body { margin: 0; } #out { display: inline-block; }</style>
            </head><body><div id="out"></div><script>\(script)</script></body></html>
            """
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            web.loadHTMLString(html, baseURL: nil)
        }
        self.web = web
        return web
    }

    private func tearDown() {
        web?.stopLoading()
        web?.navigationDelegate = nil
        web = nil
        loaded?.resume(throwing: Failure.timedOut)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    /// The web content process died (it can be killed under memory pressure); the next
    /// diagram starts a fresh one.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if webView === web { tearDown() }
    }

    /// What to tell the reader: Mermaid's own message (its parse errors name the line and
    /// what it expected), trimmed.
    static func message(for error: Error) -> String {
        switch error {
        case Failure.timedOut: return "The diagram took too long to draw."
        case Failure.missingScript: return "Mermaid is missing from this build."
        case Failure.noImage: return "The diagram came out empty."
        default: break
        }
        let ns = error as NSError
        var text = (ns.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? ns.localizedDescription
        if text.hasPrefix("Error: ") { text.removeFirst(7) }
        return text.count > 400 ? String(text.prefix(400)) + "…" : text
    }
}

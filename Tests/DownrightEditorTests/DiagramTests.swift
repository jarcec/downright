import XCTest
import AppKit
@testable import DownrightEditor

/// ```mermaid blocks draw as diagrams while the caret is elsewhere (hidden WebKit, see
/// `MermaidWebView`) and show their source when it comes in.
@MainActor
final class DiagramTests: XCTestCase {
    private let flow = "flowchart LR\n    A[Write] --> B{Mermaid?}\n    B -- yes --> C[Diagram]\n    B -- no --> D[Code]"

    private func editor(_ text: String, width: CGFloat = 800) -> (EditorController, NSWindow) {
        let c = EditorController(textStorage: NSTextStorage(string: text))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = window.contentView!.bounds
        c.textView.setSelectedRange(NSRange(location: 0, length: 0))
        window.layoutIfNeeded()
        return (c, window)
    }

    /// Wait until the renderer has finished `source` (the editor rebuilds on its own).
    private func settle(_ c: EditorController, _ source: String) async throws -> DiagramRenderer.State {
        for _ in 0..<200 {
            let state = c.diagrams.diagram(for: source, theme: c.theme).state
            if state != .rendering {
                try await Task.sleep(for: .milliseconds(50))   // let the rebuild land
                c.scrollView.layoutSubtreeIfNeeded()
                return state
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("the diagram never finished"); return .rendering
    }

    private func fragmentHeight(_ c: EditorController, at offset: Int) -> CGFloat {
        let loc = c.contentStorage.location(c.contentStorage.documentRange.location, offsetBy: offset)!
        c.layoutManager.ensureLayout(for: NSTextRange(location: loc))
        return c.layoutManager.textLayoutFragment(for: loc)?.layoutFragmentFrame.height ?? -1
    }

    private func snapshot(_ c: EditorController, _ name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["DIAGRAM_SNAPSHOTS"] else { return }
        let rep = try XCTUnwrap(c.scrollView.bitmapImageRepForCachingDisplay(in: c.scrollView.bounds))
        c.scrollView.cacheDisplay(in: c.scrollView.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }

    func testDiagramReplacesTheBlockUntilTheCaretComesIn() async throws {
        let text = "Intro line\n\n```mermaid\n\(flow)\n```\n\nAfter the diagram.\n"
        let ns = text as NSString
        let fence = ns.range(of: "```mermaid").location, sourceLine = ns.range(of: "A[Write]").location
        let (c, _) = editor(text)
        guard case .rendered(let image) = try await settle(c, flow) else { return XCTFail("not rendered") }
        XCTAssertGreaterThan(image.size.width, 200)
        try snapshot(c, "diagram-concealed")

        XCTAssertGreaterThan(fragmentHeight(c, at: fence), 60, "the fence line carries the diagram")
        XCTAssertEqual(fragmentHeight(c, at: sourceLine), 0, accuracy: 0.5, "its source is collapsed")
        XCTAssertEqual(fragmentHeight(c, at: ns.range(of: "```\n\nAfter").location), 0, accuracy: 0.5, "and so is the closing fence")

        c.textView.setSelectedRange(NSRange(location: sourceLine + 2, length: 0))
        c.scrollView.layoutSubtreeIfNeeded()
        try snapshot(c, "diagram-revealed")
        XCTAssertGreaterThan(fragmentHeight(c, at: sourceLine), 10, "the caret inside shows the source")
        XCTAssertLessThan(fragmentHeight(c, at: fence), 40, "and the fence as text, not the picture")
    }

    func testBrokenDiagramSaysWhy() async throws {
        let broken = "flowchart LR\n    A --> "
        let (c, _) = editor("x\n\n```mermaid\n\(broken)\n```\n")
        guard case .failed(let message) = try await settle(c, broken) else { return XCTFail("should fail") }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("parse error"), message)
        try snapshot(c, "diagram-broken")
    }

    func testDarkThemeDrawsADarkDiagram() async throws {
        let (c, _) = editor("x\n\n```mermaid\n\(flow)\n```\n")
        c.theme = Theme(palette: .ink)
        guard case .rendered(let image) = try await settle(c, flow) else { return XCTFail("not rendered") }
        let rep = try XCTUnwrap(image.representations.first as? NSBitmapImageRep ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let corner = try XCTUnwrap(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(corner.brightnessComponent, 0.2, "drawn on Ink's page colour")
        try snapshot(c, "diagram-ink")
    }

    func testOnlyMermaidInfoStringsAreDiagrams() {
        XCTAssertTrue(DiagramRenderer.isDiagram(info: "mermaid"))
        XCTAssertTrue(DiagramRenderer.isDiagram(info: "Mermaid title=x"))
        XCTAssertTrue(DiagramRenderer.isDiagram(info: "mermaid{.wide}"))
        XCTAssertFalse(DiagramRenderer.isDiagram(info: "mermaidjs"))
        XCTAssertFalse(DiagramRenderer.isDiagram(info: "swift"))
        XCTAssertFalse(DiagramRenderer.isDiagram(info: ""))
    }

    func testRawModeAndEmptyBlocksStayCode() {
        let (c, _) = editor("x\n\n```mermaid\n```\n")
        XCTAssertNotEqual(c.engine.decoration(forParagraphAt: 3).role, .diagramFence(info: "mermaid"), "nothing to draw yet")
        let (r, _) = editor("x\n\n```mermaid\n\(flow)\n```\n")
        r.mode = .raw
        XCTAssertNotEqual(r.engine.decoration(forParagraphAt: 3).role, .diagramFence(info: "mermaid"))
    }

    func testRichTextCopyCarriesTheDiagramWhenItIsReady() {
        let md = "Before\n\n```mermaid\n\(flow)\n```\n"
        let picture = NSImage(size: NSSize(width: 300, height: 100))
        var asked: String?
        let ready = RichTextExporter.attributedString(markdown: md) { source, _ in asked = source; return picture }
        XCTAssertEqual(asked, flow)
        var attachments = 0
        ready.enumerateAttribute(.attachment, in: NSRange(location: 0, length: ready.length)) { v, _, _ in if v != nil { attachments += 1 } }
        XCTAssertEqual(attachments, 1)
        XCTAssertFalse(ready.string.contains("flowchart"))

        let notYet = RichTextExporter.attributedString(markdown: md) { _, _ in nil }
        XCTAssertTrue(notYet.string.contains("flowchart LR"), "the source stands in")
    }
}

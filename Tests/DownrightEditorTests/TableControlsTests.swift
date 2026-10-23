import XCTest
import AppKit
import MarkdownKit
@testable import DownrightEditor

/// The grips, the toolbar and the selection they make, in a window.
@MainActor
final class TableControlsTests: XCTestCase {
    static let text = "Intro.\n\n| Vendor | Plan | Seats |\n|---|---|--:|\n| Estuary | Team | 40 |\n| Linear | Business | 25 |\n| Figma | Org | 18 |\n\nOutro.\n"
    private var c: EditorController!
    private var window: NSWindow!
    private var ns: NSString { c.textStorage.string as NSString }
    private var start: Int { ns.range(of: "| Vendor").location }

    override func setUp() {
        c = EditorController(textStorage: NSTextStorage(string: Self.text))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = c.scrollView
        c.scrollView.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        window.layoutIfNeeded()
    }

    private func caret(in needle: String) { c.textView.setSelectedRange(NSRange(location: ns.range(of: needle).location, length: 0)) }
    private var chrome: TableChromeView { c.textView.tableChrome }

    private func mouse(_ type: NSEvent.EventType, at p: NSPoint, in view: NSView, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    private func click(_ p: NSPoint) {
        chrome.mouseDown(with: mouse(.leftMouseDown, at: p, in: chrome))
        chrome.mouseUp(with: mouse(.leftMouseUp, at: p, in: chrome))
    }
    private func center(of part: TableChromeView.Part) -> NSPoint {
        let g = chrome.geometry!
        switch part {
        case .columnGrip(let i): let s = g.columnSpan(i)!; return NSPoint(x: (s.minX + s.maxX) / 2, y: g.top - 7)
        case .rowGrip(let i): let s = g.rowSpan(i)!; return NSPoint(x: g.left - TableChromeView.gripInset, y: (s.minY + s.maxY) / 2)
        case .columnGap(let k): return NSPoint(x: g.edgeX(k), y: g.top - 7)
        case .rowGap(let k): return NSPoint(x: g.left - TableChromeView.gripInset, y: g.rowEdges[k])
        case .newRow: return NSPoint(x: g.newRowRect.midX, y: g.newRowRect.midY)
        }
    }

    func testControlsShowOnlyWhileTheCaretIsInATable() {
        caret(in: "Intro")
        XCTAssertTrue(chrome.isHidden)
        caret(in: "Team")
        XCTAssertFalse(chrome.isHidden)
        let g = try! XCTUnwrap(chrome.geometry)
        XCTAssertEqual(g.columns, 3)
        XCTAssertEqual(g.rows, 4)
        XCTAssertEqual(chrome.part(at: center(of: .columnGrip(1))), .columnGrip(1))
        XCTAssertEqual(chrome.part(at: center(of: .rowGrip(2))), .rowGrip(2))
        XCTAssertEqual(chrome.part(at: center(of: .columnGap(1))), .columnGap(1))
        XCTAssertNil(chrome.hitTest(c.textView.convert(NSPoint(x: g.left + 30, y: g.rowEdges[1] + 5), to: c.textView.superview)), "the cells stay the text's")
        let outro = c.caretRect(at: ns.range(of: "Outro").location)!
        XCTAssertGreaterThan(outro.minY, g.newRowRect.maxY, "room is kept for the New row strip")
        c.mode = .view
        XCTAssertTrue(chrome.isHidden, "View mode is read-only: no controls")
    }

    func testClickingAGripSelectsItsColumnAndShowsTheToolbar() {
        caret(in: "Team")
        click(center(of: .columnGrip(2)))
        XCTAssertEqual(c.tableSelection, .column(blockStart: start, index: 2))
        let toolbar = c.textView.tableToolbar
        XCTAssertFalse(toolbar.isHidden)
        XCTAssertEqual(toolbar.kind, .column)
        XCTAssertEqual(toolbar.button(for: .align(.right))?.state, .on, "the column is right-aligned")
        XCTAssertLessThan(toolbar.frame.maxY, chrome.geometry!.top, "above the table")
        // The toolbar runs its command and keeps the moved column selected.
        toolbar.button(for: .moveColumnLeft)!.performClick(nil)
        XCTAssertTrue(ns.substring(from: 0).contains("| Vendor | Seats | Plan |\n|---|--:|---|"), ns as String)
        XCTAssertEqual(c.tableSelection, .column(blockStart: start, index: 1))
        // Moving the caret ends the selection, and the toolbar goes.
        caret(in: "Linear")
        XCTAssertNil(c.tableSelection)
        XCTAssertTrue(toolbar.isHidden)
    }

    func testKeysActOnTheSelection() {
        caret(in: "Team")
        c.selectTableRow(blockStart: start, index: 2)
        func key(_ code: UInt16, _ chars: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        }
        c.textView.keyDown(with: key(125, ""))   // ↓
        XCTAssertEqual(c.tableSelection, .row(blockStart: start, index: 3))
        c.textView.keyDown(with: key(51, "\u{7f}"))   // ⌫
        XCTAssertFalse((ns as String).contains("Figma"))
        XCTAssertNil(c.tableSelection)
        c.selectTableColumn(blockStart: start, index: 0)
        c.textView.keyDown(with: key(53, "\u{1b}"))   // Esc
        XCTAssertNil(c.tableSelection)
        XCTAssertTrue((ns as String).contains("Estuary"), "Esc only lets go")
    }

    func testCopyingASelectedRowOrColumn() {
        caret(in: "Team")
        c.selectTableRow(blockStart: start, index: 1)
        XCTAssertEqual(c.tableSelectionText()?.markdown, "| Vendor | Plan | Seats |\n|---|---|---:|\n| Estuary | Team | 40 |\n")
        XCTAssertEqual(c.tableSelectionText()?.tsv, "Estuary\tTeam\t40\n")
        c.selectTableColumn(blockStart: start, index: 1)
        XCTAssertEqual(c.tableSelectionText()?.markdown, "| Plan |\n|---|\n| Team |\n| Business |\n| Org |\n")
    }

    func testThePlusBetweenColumnsAndTheNewRowStripInsert() {
        caret(in: "Team")
        click(center(of: .columnGap(1)))
        XCTAssertTrue((ns as String).contains("| Vendor |     | Plan | Seats |"), ns as String)
        XCTAssertEqual(c.tableHit(at: c.textView.selectedRange().location)?.cellIndex, 1, "the caret waits in the new column")
        caret(in: "Team")
        click(center(of: .newRow))
        XCTAssertTrue((ns as String).contains("| Figma |     | Org | 18 |\n|     |     |     |     |\n"), ns as String)
        caret(in: "Team")
        click(center(of: .rowGap(2)))
        XCTAssertTrue((ns as String).contains("| Estuary |     | Team | 40 |\n|     |     |     |     |\n| Linear"), ns as String)
    }

    func testDraggingARowGripMovesTheRow() {
        caret(in: "Team")
        let from = center(of: .rowGrip(3))   // Figma
        let to = center(of: .rowGap(1))      // just under the header
        chrome.mouseDown(with: mouse(.leftMouseDown, at: from, in: chrome))
        chrome.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: from.x, y: from.y - 10), in: chrome))
        XCTAssertTrue(chrome.isDragging)
        chrome.mouseDragged(with: mouse(.leftMouseDragged, at: to, in: chrome))
        chrome.mouseUp(with: mouse(.leftMouseUp, at: to, in: chrome))
        XCTAssertTrue((ns as String).contains("|---|---|--:|\n| Figma | Org | 18 |\n| Estuary"), ns as String)
        XCTAssertEqual(c.tableSelection, .row(blockStart: start, index: 1), "the moved row stays selected")
        // ⌥-drag copies.
        let col = center(of: .columnGrip(0))
        chrome.mouseDown(with: mouse(.leftMouseDown, at: col, in: chrome))
        chrome.mouseDragged(with: mouse(.leftMouseDragged, at: NSPoint(x: col.x + 10, y: col.y), in: chrome))
        let end = center(of: .columnGap(3))
        chrome.mouseDragged(with: mouse(.leftMouseDragged, at: end, in: chrome))
        chrome.mouseUp(with: mouse(.leftMouseUp, at: end, in: chrome, flags: .option))
        XCTAssertTrue((ns as String).contains("| Vendor | Plan | Seats | Vendor |"), ns as String)
    }
}

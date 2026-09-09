import AppKit
import MarkdownKit

/// Structural table edits: rows and columns in and out, moves, alignment. Each operation
/// rebuilds the table's lines from their existing pieces (separators and cells kept
/// verbatim, so spacing survives), replaces the block as one undoable edit, and puts the
/// caret in the most useful cell.
extension EditorController {
    public enum TableOperation: Hashable {
        case insertRowAbove, insertRowBelow, deleteRow, moveRowUp, moveRowDown
        case insertColumnLeft, insertColumnRight, deleteColumn, moveColumnLeft, moveColumnRight
        case align(TableAlignment)
    }

    /// Line pieces: `seps.count == cells.count + 1`.
    struct RowPieces {
        var seps: [String]
        var cells: [String]
        var text: String {
            var s = ""
            for (i, c) in cells.enumerated() { s += seps[i] + c }
            return s + (seps.last ?? "")
        }
        static let emptyCell = "   "

        func padded(to n: Int) -> RowPieces {
            var p = self
            while p.cells.count < n { p = p.inserting(Self.emptyCell, at: p.cells.count) }
            return p
        }
        /// The row's own interior separator style (`" | "` in text rows, `"|"` in a tight
        /// delimiter row), so inserted columns look like their neighbours.
        var interiorSeparator: String {
            guard seps.count > 2 else { return " | " }
            // An empty cell's padding is parsed into the separator before it; normalise.
            return seps[1].contains(" ") ? " | " : "|"
        }

        func inserting(_ cell: String, at k: Int) -> RowPieces {
            var p = self
            let n = p.cells.count
            let mid = interiorSeparator
            if k >= n {
                let trailing = p.seps.removeLast()
                if trailing.trimmingCharacters(in: .whitespaces).isEmpty {
                    p.seps.append(mid); p.cells.append(cell); p.seps.append("")
                } else {
                    p.seps.append(mid); p.cells.append(cell); p.seps.append(trailing)
                }
            } else {
                p.cells.insert(cell, at: k)
                p.seps.insert(mid, at: k + 1)
            }
            return p
        }
        func deleting(_ k: Int) -> RowPieces {
            var p = self
            guard p.cells.count > 1, k < p.cells.count else { return p }
            p.cells.remove(at: k)
            p.seps.remove(at: k < p.cells.count ? k + 1 : k)
            return p
        }
    }

    private func pieces(of row: TableRow) -> RowPieces {
        let ns = textStorage.string as NSString
        return RowPieces(seps: row.separators.map { ns.substring(with: $0) }, cells: row.cells.map { ns.substring(with: $0.range) })
    }

    private static func alignmentToken(_ a: TableAlignment) -> String {
        switch a {
        case .none: return "---"
        case .left: return ":--"
        case .center: return ":-:"
        case .right: return "--:"
        }
    }

    /// Can `op` run with the caret at `offset`? Used by menu validation.
    public func canPerformTableOperation(_ op: TableOperation, at offset: Int) -> Bool {
        guard let h = tableHit(at: offset) else { return false }
        let isHeader = h.rowIndex == 0
        let bodyIndex = h.rowIndex - 1
        switch op {
        case .deleteRow, .moveRowUp, .moveRowDown: return !isHeader && (op != .moveRowUp || bodyIndex > 0) && (op != .moveRowDown || bodyIndex < h.table.rows.count - 1)
        case .deleteColumn: return h.table.columnCount > 1 && h.cellIndex != nil
        case .moveColumnLeft: return (h.cellIndex ?? 0) > 0
        case .moveColumnRight: return h.cellIndex.map { $0 < h.table.columnCount - 1 } ?? false
        case .insertColumnLeft, .insertColumnRight, .align: return h.cellIndex != nil
        case .insertRowAbove, .insertRowBelow: return true
        }
    }

    /// Current alignment of the caret's column (for menu check marks).
    public func tableColumnAlignment(at offset: Int) -> TableAlignment? {
        guard let h = tableHit(at: offset), let ci = h.cellIndex, ci < h.table.alignments.count else { return nil }
        return h.table.alignments[ci]
    }

    @discardableResult
    public func performTableOperation(_ op: TableOperation, at offset: Int) -> Bool {
        guard canPerformTableOperation(op, at: offset), let h = tableHit(at: offset) else { return false }
        let t = h.table
        let n = t.columnCount
        let ns = textStorage.string as NSString
        let column = h.cellIndex ?? 0
        let bodyIndex = h.rowIndex - 1   // -1 for header

        // Rows as pieces, all padded to the header's column count.
        var header = pieces(of: t.header).padded(to: n)
        var delimiter = pieces(of: t.delimiter).padded(to: n)
        var body = t.rows.map { pieces(of: $0).padded(to: n) }
        // Delimiter pieces may be missing alignment tokens for padded columns
        for i in 0..<delimiter.cells.count where delimiter.cells[i].trimmingCharacters(in: .whitespaces).isEmpty { delimiter.cells[i] = "---" }

        var targetRow = h.rowIndex          // index into header+body (0 = header), for caret placement
        var targetColumn = column

        let emptyRow: RowPieces = {
            let lead = header.seps.first ?? "| "
            let trail = header.seps.last ?? " |"
            var seps = [lead.isEmpty ? "" : "| "]
            seps += Array(repeating: " | ", count: max(0, n - 1))
            seps.append(trail.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " |")
            return RowPieces(seps: seps, cells: Array(repeating: RowPieces.emptyCell, count: n))
        }()

        switch op {
        case .insertRowAbove:
            let at = max(0, bodyIndex)          // above the header → first body row
            body.insert(emptyRow, at: at); targetRow = at + 1; targetColumn = 0
        case .insertRowBelow:
            let at = bodyIndex + 1
            body.insert(emptyRow, at: at); targetRow = at + 1; targetColumn = 0
        case .deleteRow:
            body.remove(at: bodyIndex); targetRow = min(bodyIndex, body.count - 1) + 1
            if body.isEmpty { targetRow = 0 }
        case .moveRowUp:
            body.swapAt(bodyIndex, bodyIndex - 1); targetRow = bodyIndex
        case .moveRowDown:
            body.swapAt(bodyIndex, bodyIndex + 1); targetRow = bodyIndex + 2
        case .insertColumnLeft, .insertColumnRight:
            let k = op == .insertColumnLeft ? column : column + 1
            header = header.inserting(RowPieces.emptyCell, at: k)
            delimiter = delimiter.inserting("---", at: k)
            body = body.map { $0.inserting(RowPieces.emptyCell, at: k) }
            targetColumn = k
        case .deleteColumn:
            header = header.deleting(column); delimiter = delimiter.deleting(column)
            body = body.map { $0.deleting(column) }
            targetColumn = min(column, n - 2)
        case .moveColumnLeft, .moveColumnRight:
            let k = op == .moveColumnLeft ? column - 1 : column + 1
            header.cells.swapAt(column, k); delimiter.cells.swapAt(column, k)
            body = body.map { var p = $0; p.cells.swapAt(column, k); return p }
            targetColumn = k
        case .align(let a):
            delimiter.cells[column] = Self.alignmentToken(a)
        }

        // Rebuild and replace the block in one edit.
        let lines = [header.text, delimiter.text] + body.map(\.text)
        let blockRange = h.block.range
        let endsWithNewline = blockRange.length > 0 && ns.character(at: blockRange.end - 1) == 10
        let replacement = lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        guard textView.shouldChangeText(in: blockRange, replacementString: replacement) else { return false }
        textStorage.replaceCharacters(in: blockRange, with: replacement)
        textView.didChangeText()

        // Caret: the target cell in the reparsed table.
        if let nh = tableHit(at: blockRange.location) {
            let rows = nh.table.allRows
            let r = min(max(0, targetRow), rows.count - 1)
            if targetColumn < rows[r].cells.count {
                let cell = rows[r].cells[targetColumn]
                textView.setSelectedRange(NSRange(location: cell.range.location, length: cell.range.length))
            } else {
                textView.setSelectedRange(NSRange(location: rows[r].range.location, length: 0))
            }
            textView.scrollRangeToVisible(textView.selectedRange())
        }
        return true
    }
}

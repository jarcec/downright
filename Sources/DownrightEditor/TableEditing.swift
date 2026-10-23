import AppKit
import MarkdownKit

/// Structural table edits: rows and columns in and out, moves, alignment. Each operation
/// rebuilds the table's lines from their existing pieces (separators and cells kept
/// verbatim, so spacing survives), replaces the block as one undoable edit, and puts the
/// caret in the most useful cell.
extension EditorController {
    public enum TableOperation: Hashable {
        case insertRowAbove, insertRowBelow, deleteRow, moveRowUp, moveRowDown, duplicateRow
        case insertColumnLeft, insertColumnRight, deleteColumn, moveColumnLeft, moveColumnRight
        case align(TableAlignment)
        /// Body rows ordered by the column's text (numbers by value), header kept on top.
        case sort(ascending: Bool)
        /// Drag and drop. The destination is a gap: `k` sits before row / column `k`
        /// (`table.allRows` indices for rows, so 1 is just under the header; the count
        /// is the end).
        case moveRow(to: Int), copyRow(to: Int), moveColumn(to: Int), copyColumn(to: Int)
    }

    /// One cell of a table, by position: the row in `table.allRows` (0 = header) and the
    /// column. What an operation acts on, and where its row or column ends up.
    public struct TableTarget: Equatable {
        public var blockStart: Int
        public var row: Int
        public var column: Int
        public init(blockStart: Int, row: Int, column: Int) { self.blockStart = blockStart; self.row = row; self.column = column }
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

    /// The table, and the caret's place in it, for the caret-driven commands (menu,
    /// shortcuts). Column commands need the caret in a cell, not in a separator.
    private func caretTarget(_ op: TableOperation, at offset: Int) -> TableTarget? {
        guard let h = tableHit(at: offset) else { return nil }
        if h.cellIndex == nil, op.isColumnOperation { return nil }
        return TableTarget(blockStart: h.block.range.location, row: h.rowIndex, column: h.cellIndex ?? 0)
    }

    /// Can `op` run with the caret at `offset`? Used by menu validation.
    public func canPerformTableOperation(_ op: TableOperation, at offset: Int) -> Bool {
        caretTarget(op, at: offset).map { canPerformTableOperation(op, on: $0) } ?? false
    }

    public func canPerformTableOperation(_ op: TableOperation, on target: TableTarget) -> Bool {
        guard let t = table(at: target.blockStart), target.row >= 0, target.row < t.allRows.count,
              target.column >= 0, target.column < t.columnCount else { return false }
        let rows = t.allRows.count, n = t.columnCount, r = target.row, c = target.column
        switch op {
        case .deleteRow, .duplicateRow: return r > 0
        case .moveRowUp: return r > 1
        case .moveRowDown: return r > 0 && r < rows - 1
        case .deleteColumn: return n > 1
        case .moveColumnLeft: return c > 0
        case .moveColumnRight: return c < n - 1
        case .insertColumnLeft, .insertColumnRight, .align, .insertRowAbove, .insertRowBelow: return true
        case .sort: return t.rows.count > 1
        case .moveRow(let k): return r > 0 && k >= 1 && k <= rows && k != r && k != r + 1
        case .copyRow(let k): return r > 0 && k >= 1 && k <= rows
        case .moveColumn(let k): return k >= 0 && k <= n && k != c && k != c + 1
        case .copyColumn(let k): return k >= 0 && k <= n
        }
    }

    /// Current alignment of the caret's column (for menu check marks).
    public func tableColumnAlignment(at offset: Int) -> TableAlignment? {
        guard let h = tableHit(at: offset), let ci = h.cellIndex, ci < h.table.alignments.count else { return nil }
        return h.table.alignments[ci]
    }

    public func tableColumnAlignment(blockStart: Int, column: Int) -> TableAlignment? {
        guard let t = table(at: blockStart), column < t.alignments.count else { return nil }
        return t.alignments[column]
    }

    /// Whether the body rows are already in order by `column`: true ascending, false
    /// descending, nil neither (or too few rows to tell).
    public func tableSortOrder(blockStart: Int, column: Int) -> Bool? {
        guard let t = table(at: blockStart), t.rows.count > 1 else { return nil }
        let keys = t.rows.map { sortKey(of: $0, column: column) }
        if zip(keys, keys.dropFirst()).allSatisfy({ !Self.sortsBefore($1, $0) }) { return true }
        if zip(keys, keys.dropFirst()).allSatisfy({ !Self.sortsBefore($0, $1) }) { return false }
        return nil
    }

    private func sortKey(of row: TableRow, column: Int) -> String {
        guard column < row.cells.count else { return "" }
        return (textStorage.string as NSString).substring(with: row.cells[column].range).trimmingCharacters(in: .whitespaces)
    }

    /// Text order with numbers compared by value (Finder's order); empty cells last.
    nonisolated static func sortsBefore(_ a: String, _ b: String) -> Bool {
        if a.isEmpty != b.isEmpty { return b.isEmpty }
        return a.localizedStandardCompare(b) == .orderedAscending
    }

    func table(at blockStart: Int) -> Table? {
        guard let block = document.path(containing: blockStart).last(where: { if case .table = $0.kind { return true }; return false }),
              block.range.location == blockStart, case .table(let t) = block.kind else { return nil }
        return t
    }

    /// The caret-driven form: acts where the caret is and leaves it in the most useful cell.
    @discardableResult
    public func performTableOperation(_ op: TableOperation, at offset: Int) -> Bool {
        guard let target = caretTarget(op, at: offset) else { return false }
        return performTableOperation(op, on: target) != nil
    }

    /// Runs `op` on the row / column of `target` as one undoable edit and returns where
    /// that row or column is afterwards (the new one, for an insert or a copy), or nil if
    /// it could not run. The caret goes to that cell, its text selected.
    @discardableResult
    public func performTableOperation(_ op: TableOperation, on target: TableTarget) -> TableTarget? {
        guard canPerformTableOperation(op, on: target), let t = table(at: target.blockStart),
              let block = document.path(containing: target.blockStart).last(where: { if case .table = $0.kind { return true }; return false }) else { return nil }
        let n = t.columnCount
        let ns = textStorage.string as NSString
        let column = target.column
        let bodyIndex = target.row - 1   // -1 for header

        // Rows as pieces, all padded to the header's column count.
        var header = pieces(of: t.header).padded(to: n)
        var delimiter = pieces(of: t.delimiter).padded(to: n)
        var body = t.rows.map { pieces(of: $0).padded(to: n) }
        // Delimiter pieces may be missing alignment tokens for padded columns
        for i in 0..<delimiter.cells.count where delimiter.cells[i].trimmingCharacters(in: .whitespaces).isEmpty { delimiter.cells[i] = "---" }

        var targetRow = target.row          // index into header+body (0 = header), for caret placement
        var targetColumn = column

        let emptyRow: RowPieces = {
            let lead = header.seps.first ?? "| "
            let trail = header.seps.last ?? " |"
            var seps = [lead.isEmpty ? "" : "| "]
            seps += Array(repeating: " | ", count: max(0, n - 1))
            seps.append(trail.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " |")
            return RowPieces(seps: seps, cells: Array(repeating: RowPieces.emptyCell, count: n))
        }()

        /// Every row's cell `c`, header and delimiter included, to re-insert elsewhere.
        func columnCells(_ c: Int) -> (header: String, delimiter: String, body: [String]) {
            (header.cells[c], delimiter.cells[c], body.map { $0.cells[c] })
        }
        func insertColumn(_ cells: (header: String, delimiter: String, body: [String]), at k: Int) {
            header = header.inserting(cells.header, at: k)
            delimiter = delimiter.inserting(cells.delimiter, at: k)
            body = zip(body, cells.body).map { $0.inserting($1, at: k) }
        }

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
        case .duplicateRow:
            body.insert(body[bodyIndex], at: bodyIndex + 1); targetRow = bodyIndex + 2
        case .moveRowUp:
            body.swapAt(bodyIndex, bodyIndex - 1); targetRow = bodyIndex
        case .moveRowDown:
            body.swapAt(bodyIndex, bodyIndex + 1); targetRow = bodyIndex + 2
        case .moveRow(let k), .copyRow(let k):
            let row = body[bodyIndex]
            var at = k - 1
            if case .moveRow = op {
                body.remove(at: bodyIndex)
                if at > bodyIndex { at -= 1 }
            }
            body.insert(row, at: at); targetRow = at + 1
        case .insertColumnLeft, .insertColumnRight:
            let k = op == .insertColumnLeft ? column : column + 1
            insertColumn((RowPieces.emptyCell, "---", Array(repeating: RowPieces.emptyCell, count: body.count)), at: k)
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
        case .moveColumn(let k), .copyColumn(let k):
            let cells = columnCells(column)
            var at = k
            if case .moveColumn = op {
                header = header.deleting(column); delimiter = delimiter.deleting(column)
                body = body.map { $0.deleting(column) }
                if at > column { at -= 1 }
            }
            insertColumn(cells, at: at); targetColumn = at
        case .align(let a):
            delimiter.cells[column] = Self.alignmentToken(a)
        case .sort(let ascending):
            let keyed = zip(body, t.rows).map { ($0, sortKey(of: $1, column: column)) }
            let sorted = keyed.enumerated().sorted { a, b in
                let (x, y) = (a.element.1, b.element.1)
                if x.isEmpty != y.isEmpty { return y.isEmpty }   // empty cells last either way
                let before = ascending ? Self.sortsBefore(x, y) : Self.sortsBefore(y, x)
                let after = ascending ? Self.sortsBefore(y, x) : Self.sortsBefore(x, y)
                return before || (!after && a.offset < b.offset)   // stable
            }
            body = sorted.map(\.element.0); targetRow = 0
        }

        // Rebuild and replace the block in one edit.
        let lines = [header.text, delimiter.text] + body.map(\.text)
        let blockRange = block.range
        let endsWithNewline = blockRange.length > 0 && ns.character(at: blockRange.end - 1) == 10
        let replacement = lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        guard textView.shouldChangeText(in: blockRange, replacementString: replacement) else { return nil }
        textStorage.replaceCharacters(in: blockRange, with: replacement)
        textView.didChangeText()

        // Caret: the target cell in the reparsed table (an edit that no longer parses as a
        // table, rare with ragged pipe-less rows, leaves the caret where it was).
        guard let nt = table(at: blockRange.location) else { return TableTarget(blockStart: blockRange.location, row: targetRow, column: targetColumn) }
        let rows = nt.allRows
        let r = min(max(0, targetRow), rows.count - 1)
        let c = min(max(0, targetColumn), max(0, rows[r].cells.count - 1))
        if c < rows[r].cells.count {
            let cell = rows[r].cells[c]
            textView.setSelectedRange(NSRange(location: cell.range.location, length: cell.range.length))
        } else {
            textView.setSelectedRange(NSRange(location: rows[r].range.location, length: 0))
        }
        textView.scrollRangeToVisible(textView.selectedRange())
        return TableTarget(blockStart: blockRange.location, row: r, column: c)
    }
}

extension EditorController.TableOperation {
    var isColumnOperation: Bool {
        switch self {
        case .insertColumnLeft, .insertColumnRight, .deleteColumn, .moveColumnLeft, .moveColumnRight, .align, .sort, .moveColumn, .copyColumn: return true
        default: return false
        }
    }
}

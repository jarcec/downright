import AppKit
import MarkdownKit

/// Making tables: Insert Table, a typed header row that becomes a table on Return, and
/// cells pasted from a spreadsheet or a web page.
extension EditorController {
    // MARK: - Insert Table

    /// Inserts an empty table with `columns` columns and `rows` rows (the header counts
    /// as one) as its own block at the caret, and puts the caret in its first cell.
    @discardableResult
    public func insertTable(columns: Int, rows: Int) -> Bool {
        let columns = max(1, columns), rows = max(1, rows)
        let header = Array(repeating: RowPieces.emptyCell, count: columns)
        let body = Array(repeating: header, count: rows - 1)
        return insertTableBlock(header: header, body: body)
    }

    /// Puts a table made of `header` and `body` cells (already escaped) on its own lines
    /// at the caret: a blank line before and after it unless one is there already, and
    /// the caret in the first header cell.
    @discardableResult
    func insertTableBlock(header: [String], body: [[String]], caretInFirstBodyCell: Bool = false) -> Bool {
        guard mode != .view, let width = ([header] + body).map(\.count).max(), width > 0 else { return false }
        func line(_ cells: [String]) -> String {
            let padded = cells + Array(repeating: RowPieces.emptyCell, count: width - cells.count)
            return "| " + padded.map { $0.isEmpty ? RowPieces.emptyCell : $0 }.joined(separator: " | ") + " |"
        }
        let table = ([line(header), "|" + Array(repeating: "---", count: width).joined(separator: "|") + "|"] + body.map(line)).joined(separator: "\n")

        let ns = textStorage.string as NSString
        let sel = textView.selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineText = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty line (or a selection) is replaced; otherwise the table goes after the line.
        let target: NSRange
        if sel.length > 0 { target = sel }
        else if lineText.isEmpty { target = NSRange(location: lineRange.location, length: max(0, lineRange.length - (ns.substring(with: lineRange).hasSuffix("\n") ? 1 : 0))) }
        else { target = NSRange(location: lineRange.end - (ns.substring(with: lineRange).hasSuffix("\n") ? 1 : 0), length: 0) }

        let before = target.location == 0 ? "" : ns.substring(with: NSRange(location: 0, length: target.location))
        let after = ns.substring(from: target.end)
        var lead = ""
        if !before.isEmpty {
            if !before.hasSuffix("\n") { lead = "\n\n" } else if !before.hasSuffix("\n\n") { lead = "\n" }
        }
        var trail = ""
        if after.isEmpty { trail = "\n" }
        else if after == "\n" || after.hasPrefix("\n\n") { trail = "" }   // the document's last line, or a blank line already
        else if after.hasPrefix("\n") { trail = "\n" }
        else { trail = "\n\n" }
        let replacement = lead + table + trail
        guard textView.shouldChangeText(in: target, replacementString: replacement) else { return false }
        textStorage.replaceCharacters(in: target, with: replacement)
        textView.didChangeText()

        let tableStart = target.location + (lead as NSString).length
        if let t = self.table(at: tableStart) {
            let row = caretInFirstBodyCell ? (t.rows.first ?? t.header) : t.header
            if let cell = row.cells.first {
                textView.setSelectedRange(NSRange(location: cell.range.location, length: cell.range.length))
            }
        } else {
            textView.setSelectedRange(NSRange(location: tableStart + 2, length: 0))
        }
        textView.scrollRangeToVisible(textView.selectedRange())
        return true
    }

    // MARK: - A typed header row

    /// Return at the end of a line like `| Name | Role |` that is not a table yet: write
    /// its delimiter row and an empty row under it, caret in that row's first cell.
    func completeTypedTableHeader(at offset: Int) -> Bool {
        guard mode == .live, textView.selectedRange().length == 0, tableHit(at: offset) == nil else { return false }
        if let leaf = document.path(containing: offset).last, leaf.isVerbatim { return false }   // code, HTML: leave it
        let ns = textStorage.string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
        var content = ns.substring(with: lineRange)
        if content.hasSuffix("\n") { content.removeLast() }
        let lineEnd = lineRange.location + (content as NSString).length
        guard offset == lineEnd else { return false }
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.hasPrefix("|"), trimmed.hasSuffix("|") else { return false }
        let cells = Self.splitCells(String(trimmed.dropFirst().dropLast()))
        guard !cells.isEmpty, cells.contains(where: { !$0.isEmpty }) else { return false }
        let indent = String(content.prefix { $0 == " " || $0 == "\t" })
        let delimiter = indent + "|" + Array(repeating: "---", count: cells.count).joined(separator: "|") + "|"
        let empty = indent + "| " + Array(repeating: RowPieces.emptyCell, count: cells.count).joined(separator: " | ") + " |"
        let insertion = "\n" + delimiter + "\n" + empty
        let at = NSRange(location: lineEnd, length: 0)
        guard textView.shouldChangeText(in: at, replacementString: insertion) else { return false }
        textStorage.replaceCharacters(in: at, with: insertion)
        textView.didChangeText()
        let rowStart = lineEnd + 1 + (delimiter as NSString).length + 1
        if let h = tableHit(at: rowStart), let cell = h.row.cells.first {
            textView.setSelectedRange(NSRange(location: cell.range.location, length: cell.range.length))
        } else {
            textView.setSelectedRange(NSRange(location: rowStart + (indent as NSString).length + 2, length: 0))
        }
        return true
    }

    /// Cells of a row's text between its outer pipes, split on unescaped pipes, trimmed.
    nonisolated static func splitCells(_ s: String) -> [String] {
        var cells: [String] = [], current = "", escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == "|" { cells.append(current); current = ""; continue }
            current.append(ch)
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Pasting cells

    /// Cells on the pasteboard: tab-separated text (what Numbers and Excel copy, and what
    /// a copied row or column carries) or the first table of copied HTML. A plain string
    /// counts only when it is clearly a grid: two lines or more, each with the same
    /// number of tabs.
    nonisolated static func pastedCells(from pb: NSPasteboard) -> [[String]]? {
        if let tsv = pb.string(forType: MarkdownTextView.tabSeparatedType), let cells = grid(fromTabSeparated: tsv, strict: false) { return cells }
        if let s = pb.string(forType: .string), let cells = grid(fromTabSeparated: s, strict: true) { return cells }
        if let html = pb.data(forType: .html), let cells = grid(fromHTML: html) { return cells }
        return nil
    }

    nonisolated static func grid(fromTabSeparated text: String, strict: Bool) -> [[String]]? {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        let rows = lines.map { $0.components(separatedBy: "\t") }
        if strict {
            guard rows.count >= 2, let n = rows.first?.count, n >= 2, rows.allSatisfy({ $0.count == n }) else { return nil }
        }
        return rows
    }

    nonisolated static func grid(fromHTML data: Data) -> [[String]]? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              text.range(of: "<table", options: .caseInsensitive) != nil,
              let doc = try? XMLDocument(data: data, options: [.documentTidyHTML]),
              let rows = try? doc.nodes(forXPath: "(//table)[1]//tr"), !rows.isEmpty else { return nil }
        let grid: [[String]] = rows.compactMap { tr in
            let cells = (tr.children ?? []).filter { ["td", "th"].contains($0.name?.lowercased() ?? "") }
            return cells.isEmpty ? nil : cells.map { ($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return grid.count >= 1 && (grid.first?.count ?? 0) >= 1 ? grid : nil
    }

    /// A cell's text made safe for a table: one line, pipes escaped.
    nonisolated static func tableCellText(_ s: String) -> String {
        s.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "|", with: "\\|")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Paste cells: inside a table they fill the cells from the caret's onward (adding
    /// rows at the end as needed; columns past the table's last are dropped); elsewhere
    /// they become a new table, the first row its header.
    func pasteTableCells(from pb: NSPasteboard = .general) -> Bool {
        guard mode == .live, let raw = Self.pastedCells(from: pb) else { return false }
        let cells = raw.map { $0.map(Self.tableCellText) }
        let caret = textView.selectedRange().location
        if let h = tableHit(at: caret) {
            return fillTableCells(blockStart: h.block.range.location, row: h.rowIndex, column: h.cellIndex ?? 0, with: cells)
        }
        if let leaf = document.path(containing: caret).last, leaf.isVerbatim { return false }
        return insertTableBlock(header: cells[0], body: Array(cells.dropFirst()), caretInFirstBodyCell: cells.count > 1)
    }

    /// Overwrites cells starting at (`row`, `column`) with `values`, as one edit.
    func fillTableCells(blockStart: Int, row: Int, column: Int, with values: [[String]]) -> Bool {
        guard let t = table(at: blockStart), let block = document.path(containing: blockStart).last(where: { if case .table = $0.kind { return true }; return false }) else { return false }
        let n = t.columnCount
        var all = t.allRows.map { pieces(of: $0).padded(to: n) }
        let template: RowPieces = {
            var seps = [(all.first?.seps.first ?? "| ").isEmpty ? "" : "| "]
            seps += Array(repeating: " | ", count: max(0, n - 1))
            seps.append((all.first?.seps.last ?? " |").trimmingCharacters(in: .whitespaces).isEmpty ? "" : " |")
            return RowPieces(seps: seps, cells: Array(repeating: RowPieces.emptyCell, count: n))
        }()
        for (i, line) in values.enumerated() {
            let r = row + i
            while r >= all.count { all.append(template) }
            for (j, value) in line.enumerated() where column + j < n {
                all[r].cells[column + j] = value.isEmpty ? RowPieces.emptyCell : value
            }
        }
        let delimiter = pieces(of: t.delimiter).padded(to: n)
        let lines = [all[0].text, delimiter.text] + all.dropFirst().map(\.text)
        let ns = textStorage.string as NSString
        let range = block.range
        let endsWithNewline = range.length > 0 && ns.character(at: range.end - 1) == 10
        let replacement = lines.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return false }
        textStorage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        // Caret after the last pasted cell.
        if let nt = table(at: range.location) {
            let rows = nt.allRows
            let r = min(row + values.count - 1, rows.count - 1)
            let c = min(column + max(0, (values.last?.count ?? 1) - 1), rows[r].cells.count - 1)
            if c >= 0 { textView.setSelectedRange(NSRange(location: rows[r].cells[c].range.end, length: 0)) }
        }
        return true
    }
}

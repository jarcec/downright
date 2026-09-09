import Foundation

// MARK: - Incremental reparse (plan §4 2f)

extension MarkdownParser {
    /// Reparse after an edit, reusing the previous parse outside the affected region.
    ///
    /// Parsing restarts one top-level block *before* the block containing the edit (a new
    /// line can turn the previous paragraph into a setext heading, join two lists, or lazily
    /// continue a paragraph) and runs forward until the parser closes a block at exactly the
    /// position where an untouched old block used to start (shifted by the edit). From
    /// there the old blocks are reused with their ranges shifted. Falls back to a full parse
    /// when link reference definitions are involved (they affect inline parsing everywhere),
    /// or when the edit reaches the document start (frontmatter).
    ///
    /// - Parameters:
    ///   - edit: the replaced range in the *new* source.
    ///   - delta: new length minus old length.
    public static func reparse(previous old: Document, source: String, edit: NSRange, delta: Int, dialect: Dialect = .gfm) -> Document {
        let buf = Array(source.utf16)
        guard old.length + delta == buf.count, !old.blocks.isEmpty else { return parse(utf16: buf, dialect: dialect) }

        let editStart = min(edit.location, buf.count)
        let newEditEnd = min(edit.location + edit.length, buf.count)
        let oldEditEnd = newEditEnd - delta
        let count = old.blocks.count
        let i0 = old.blocks.firstIndex(where: { $0.range.end > editStart }) ?? count
        let startBlock = max(0, i0 - 1)
        if startBlock == 0 { return parse(utf16: buf, dialect: dialect) }

        // Old blocks that start beyond the old edit end are resync candidates, keyed by
        // where they start in the new text.
        var candidates: [Int: Int] = [:]
        for j in min(i0 + 1, count)..<count where old.blocks[j].range.location >= oldEditEnd {
            candidates[old.blocks[j].range.location + delta] = j
        }

        let startOffset = old.blocks[startBlock].range.location
        let parser = BlockParser(source: buf, dialect: dialect, references: old.references)
        let startLine = parser.lineIndex.line(containing: startOffset)
        let (blocks, newReferences, stoppedAt) = parser.parseLines(from: startLine) { offset in
            offset >= newEditEnd && candidates[offset] != nil
        }

        let resumeIndex = stoppedAt.flatMap { candidates[$0] } ?? count
        func isLRD(_ b: Block) -> Bool { if case .linkReferenceDefinition = b.kind { return true }; return false }
        // A definition is peeled off the paragraph it starts, so the paragraph after it is
        // the one top-level block whose parse depends on its predecessor: check one block
        // before the restart point too, and also just past the resume point.
        let lrdCheck = max(0, startBlock - 1)..<min(count, resumeIndex + 1)
        if !newReferences.isEmpty || blocks.contains(where: isLRD) || old.blocks[lrdCheck].contains(where: isLRD) {
            return parse(utf16: buf, dialect: dialect)
        }

        var result = Array(old.blocks[0..<startBlock])
        result.append(contentsOf: blocks)
        if resumeIndex < count {
            result.append(contentsOf: old.blocks[resumeIndex...].map { $0.shifted(by: delta) })
        }
        return Document(blocks: result, length: buf.count, references: old.references, sourceString: source)
    }
}

// MARK: - Range shifting

extension NSRange {
    func shifted(by d: Int) -> NSRange { NSRange(location: location + d, length: length) }
}

extension Inline {
    public func shifted(by d: Int) -> Inline {
        Inline(kind: kind, range: range.shifted(by: d), markerRanges: markerRanges.map { $0.shifted(by: d) }, children: children.map { $0.shifted(by: d) })
    }
}

extension TableRow {
    func shifted(by d: Int) -> TableRow {
        TableRow(range: range.shifted(by: d),
                 cells: cells.map { TableCell(range: $0.range.shifted(by: d), inlines: $0.inlines.map { $0.shifted(by: d) }) },
                 separators: separators.map { $0.shifted(by: d) })
    }
}

extension Block {
    public func shifted(by d: Int) -> Block {
        let kind: Kind
        switch self.kind {
        case .setextHeading(let level, let underline): kind = .setextHeading(level: level, underline: underline.shifted(by: d))
        case .fencedCode(let open, let close, let info): kind = .fencedCode(openFence: open.shifted(by: d), closeFence: close?.shifted(by: d), info: info)
        case .listItem(let marker, let indent, let task):
            kind = .listItem(marker: marker.shifted(by: d), contentIndent: indent, task: task.map { TaskMarker(state: $0.state, range: $0.range.shifted(by: d)) })
        case .table(let t):
            kind = .table(Table(header: t.header.shifted(by: d), delimiterRow: t.delimiterRow.shifted(by: d), delimiter: t.delimiter.shifted(by: d), alignments: t.alignments, rows: t.rows.map { $0.shifted(by: d) }))
        default: kind = self.kind
        }
        return Block(kind: kind, range: range.shifted(by: d), markerRanges: markerRanges.map { $0.shifted(by: d) },
                     contentRanges: contentRanges.map { $0.shifted(by: d) }, children: children.map { $0.shifted(by: d) },
                     inlines: inlines.map { $0.shifted(by: d) })
    }
}

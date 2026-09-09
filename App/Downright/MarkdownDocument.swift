import AppKit
import os

let docLog = Logger(subsystem: "com.jarcec.Downright", category: "document")

/// One Markdown file. The live text lives in `textStorage`, which the editor edits in
/// place; read/write go through `TextFileFormat` for byte fidelity.
final class MarkdownDocument: NSDocument {
    let textStorage = NSTextStorage()
    private(set) var format = TextFileFormat()

    override class var autosavesInPlace: Bool { true }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let (text, fmt) = try TextFileFormat.decode(data)
        format = fmt
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: text)
        docLog.notice("read \(data.count) bytes (\(text.utf16.count) chars) from \(self.fileURL?.path ?? "<untitled>", privacy: .public)")
        for wc in windowControllers { (wc as? DocumentWindowController)?.documentDidReload() }
    }

    override func data(ofType typeName: String) throws -> Data {
        let data = format.encode(textStorage.string)
        docLog.notice("write \(data.count) bytes to \(self.fileURL?.path ?? "<untitled>", privacy: .public)")
        return data
    }

    override func write(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                        originalContentsURL absoluteOriginalContentsURL: URL?) throws {
        do {
            try super.write(to: url, ofType: typeName, for: saveOperation, originalContentsURL: absoluteOriginalContentsURL)
        } catch {
            docLog.error("write FAILED to \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    override func read(from url: URL, ofType typeName: String) throws {
        do {
            try super.read(from: url, ofType: typeName)
        } catch {
            docLog.error("read FAILED from \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - External changes (TRD §8)

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        Task { @MainActor [weak self] in self?.reloadIfChangedExternally() }
    }

    @MainActor
    private func reloadIfChangedExternally() {
        guard let url = fileURL else { return }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else {
            docLog.notice("external change: cannot stat \(url.path, privacy: .public)")
            return
        }
        if let known = fileModificationDate, modified <= known { return }
        docLog.notice("external change detected for \(url.path, privacy: .public); edited=\(self.isDocumentEdited)")
        guard !isDocumentEdited else { return }   // NSDocument warns at save time for the edited case (v0)
        do {
            try revert(toContentsOf: url, ofType: fileType ?? "net.daringfireball.markdown")
        } catch {
            docLog.error("reload FAILED for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

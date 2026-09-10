import AppKit
import DownrightEditor
import UniformTypeIdentifiers
import os

let docLog = Logger(subsystem: "com.jarcec.Downright", category: "document")

/// One Markdown file. The live text lives in `textStorage`, which the editor edits in
/// place; read/write go through `TextFileFormat` for byte fidelity.
final class MarkdownDocument: NSDocument {
    let textStorage = NSTextStorage()
    private(set) var format = TextFileFormat()
    /// Set by the window controller: called when the file changed on disk while the
    /// document has unsaved edits, so the window can ask what to do.
    var externalChangeWhileEdited: (() -> Void)?
    private var acknowledgedDiskDate: Date?

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

    // MARK: - Printing and PDF export

    /// A text view holding the rendered document at print size, laid out to the page width.
    private func printView(for printInfo: NSPrintInfo) -> NSTextView {
        var theme = Settings.theme
        theme.bodySize = 11
        let rich = RichTextExporter.attributedString(markdown: textStorage.string, theme: theme)
        let width = printInfo.imageablePageBounds.width
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(rich)
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.sizeToFit()
        return view
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        for (k, v) in printSettings { info.dictionary()[k] = v }
        info.verticalPagination = .automatic
        info.horizontalPagination = .fit
        info.isVerticallyCentered = false
        let op = NSPrintOperation(view: printView(for: info), printInfo: info)
        op.jobTitle = displayName
        return op
    }

    /// File > Export as PDF…: the print operation, saved straight to a file.
    @objc func exportPDF(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? displayName ?? "Document") + ".pdf"
        guard let window = windowControllers.first?.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let info = self.printInfo.copy() as! NSPrintInfo
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            info.verticalPagination = .automatic
            info.horizontalPagination = .fit
            info.isVerticallyCentered = false
            let op = NSPrintOperation(view: self.printView(for: info), printInfo: info)
            op.showsPrintPanel = false
            op.showsProgressPanel = false
            op.jobTitle = self.displayName
            if !op.run() { docLog.error("PDF export failed for \(url.path, privacy: .public)") }
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
        if let ack = acknowledgedDiskDate, modified <= ack { return }
        docLog.notice("external change detected for \(url.path, privacy: .public); edited=\(self.isDocumentEdited)")
        if isDocumentEdited {
            externalChangeWhileEdited?()
        } else {
            reloadFromDisk()
        }
    }

    /// Discard in-memory edits and re-read the file.
    func reloadFromDisk() {
        guard let url = fileURL else { return }
        do {
            try revert(toContentsOf: url, ofType: fileType ?? "net.daringfireball.markdown")
        } catch {
            docLog.error("reload FAILED for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Keep the in-memory edits: adopt the on-disk modification date so the next save
    /// overwrites without NSDocument's "modified by another application" alert.
    func keepEditsDespiteExternalChange() {
        guard let url = fileURL, let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return }
        acknowledgedDiskDate = modified
        fileModificationDate = modified
    }
}

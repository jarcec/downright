import AppKit

/// Non-modal notice strip at the top of a document window (e.g. "changed on disk").
@MainActor
final class NoticeBarView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let buttons = NSStackView()
    private var heightConstraint: NSLayoutConstraint!
    private var actions: [() -> Void] = []
    static let height: CGFloat = 32

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor

        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label); addSubview(buttons)

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Show the bar; each action's handler runs and the bar hides.
    func show(_ message: String, actions: [(title: String, handler: () -> Void)]) {
        label.stringValue = message
        buttons.views.forEach { $0.removeFromSuperview() }
        self.actions = actions.map(\.handler)
        for (i, a) in actions.enumerated() {
            let b = NSButton(title: a.title, target: self, action: #selector(tapped(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.tag = i
            if i == 0 { b.keyEquivalent = "\r" }
            buttons.addArrangedSubview(b)
        }
        isHidden = false
        heightConstraint.constant = Self.height
    }

    func hide() {
        isHidden = true
        heightConstraint.constant = 0
    }

    @objc private func tapped(_ sender: NSButton) {
        let handler = actions[sender.tag]
        hide()
        handler()
    }
}

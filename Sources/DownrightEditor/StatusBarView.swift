import AppKit

/// Bottom status bar: leading text (position, stats, editor mode) and trailing text
/// (detected Markdown dialect).
@MainActor
public final class StatusBarView: NSView {
    public static let height: CGFloat = 22

    private let leading = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    private let separator = NSBox()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        for label in [leading, trailing] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        trailing.alignment = .right
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 12),
        ])
        leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Deliberately no draw(_:) override: filling `dirtyRect` here blanked every sibling
    // view in the window (ChromeRenderingTests reproduces it). The window background
    // shows through, which is the intended look.

    public var leadingText: String {
        get { leading.stringValue }
        set { leading.stringValue = newValue }
    }

    public var trailingText: String {
        get { trailing.stringValue }
        set { trailing.stringValue = newValue }
    }
}

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DownrightKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownKit", targets: ["MarkdownKit"]),
        .library(name: "DownrightEditor", targets: ["DownrightEditor"]),
    ],
    targets: [
        // Pure Swift. Never imports AppKit — keeps the parser testable in seconds, headless.
        .target(name: "MarkdownKit"),
        // AppKit/TextKit 2: decoration, reveal policy, layout fragments, text view.
        .target(name: "DownrightEditor", dependencies: ["MarkdownKit"]),
        .testTarget(name: "MarkdownKitTests", dependencies: ["MarkdownKit"]),
        .testTarget(name: "DownrightEditorTests", dependencies: ["DownrightEditor"]),
    ]
)

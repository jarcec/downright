// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DownrightKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownKit", targets: ["MarkdownKit"]),
        .library(name: "DownrightEditor", targets: ["DownrightEditor"]),
        .library(name: "DownrightConfig", targets: ["DownrightConfig"]),
    ],
    targets: [
        // Pure Swift. Never imports AppKit — keeps the parser testable in seconds, headless.
        .target(name: "MarkdownKit"),
        // AppKit/TextKit 2: decoration, reveal policy, layout fragments, text view.
        // Mermaid 11.4.1 (MIT) renders ```mermaid blocks in a hidden WebKit view.
        .target(name: "DownrightEditor", dependencies: ["MarkdownKit"],
                resources: [.copy("Resources/mermaid.min.js"), .copy("Resources/mermaid-LICENSE.txt")]),
        // Pure Swift: the settings file format (a small TOML subset).
        .target(name: "DownrightConfig"),
        .testTarget(name: "MarkdownKitTests", dependencies: ["MarkdownKit"]),
        .testTarget(name: "DownrightConfigTests", dependencies: ["DownrightConfig"]),
        .testTarget(name: "DownrightEditorTests", dependencies: ["DownrightEditor"]),
    ]
)

# M0 spike — TextKit 2 concealment

Headless experiments backing `designs/02-TDs/M0-FINDINGS.md`.
No window server or app bundle needed; each file compiles and runs standalone.

```sh
swiftc -O e3.swift -o e3 && ./e3     # the decisive one: 4 concealment strategies compared
swiftc -O e4.swift -o e4 && ./e4     # wrapping, whole-line concealment, performance
swiftc -O e5.swift -o e5 && ./e5     # live NSTextView: typing, copy fidelity, caret geometry
```

| File | Question |
|---|---|
| `e1.swift` | Does `NSTextContentStorage` paragraph substitution accept a length change at all? |
| `e2.swift` | What happens to fragment enumeration, caret navigation and hit-testing when it does? |
| `e3.swift` | Baseline vs. deleting vs. ZWSP vs. zero-size-font, head to head |
| `e4.swift` | Soft wrap, whole-line concealment, 1 MB / 10 MB performance |
| `e5.swift` | Real `NSTextView`: live typing, source fidelity, caret rects |

Measured on macOS 27.0 (26A5425a), Xcode 26.6, Swift 6.3.3, arm64.

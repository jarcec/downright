# Spike — wrapping table cells

Headless experiments on whether a too-wide table can wrap to the window width.
Each file compiles and runs standalone, no app bundle needed.

```sh
swiftc -O e1.swift -o e1 && ./e1                      # custom per-cell line fragments
SPIKE_SUPERLINES=1 ./e1                               # same fragment, built-in lines
swiftc -O e2.swift -o e2 && ./e2                      # pipe → U+2028 substitution (stacked cells)
```

| File | Question |
|---|---|
| `e1.swift` | Can a custom `NSTextLayoutFragment` present a row as per-cell *wrapped* `NSTextLineFragment`s, with caret, hit-testing and arrow navigation following? |
| `e2.swift` | Does substituting each `\|` with a LINE SEPARATOR (same length) stack the cells on real TextKit lines, and does the caret mapping hold? |

## Findings (macOS 27.0, Swift 6.3)

**e1 — a real grid with wrapped cells is not reachable through TextKit 2's public API.**

- Stacking and drawing work: the layout manager honours the overridden
  `layoutFragmentFrame` height and the next paragraph lands below the taller row.
- Arrow navigation works: `NSTextSelectionNavigation` reads the public
  `textLineFragments` and `typographicBounds`, so ↓ walks the wrapped cell line by line.
- Caret and selection geometry do **not**: `enumerateTextSegments` returns zero rects
  for every location in the row. Returning `super.textLineFragments` from the same
  fragment gives correct (single-line) rects, so the enumerator does use the public
  getter — but then reads private metrics that a hand-made `NSTextLineFragment`
  (`init(attributedString:range:)`) lacks; overriding every public geometry method
  changes nothing.
- Mouse hit-testing (`textSelections(interactingAt:)`) resolves every point in the row
  to the end of the document.

A grid with wrapped cells would therefore need the app to draw its own caret and
selection in table rows and to take over mouse hit-testing there. That is the
"table live-editing proves impractical" risk (TRD R4) in another guise.

**e2 — stacked cells on real lines work.**

- `|` → U+2028 is a same-length substitution, so the caret mapping is the identity as
  in the M0 findings; typing lands at the right source offset.
- Each cell becomes its own line within the paragraph, wrapping at the container
  width with `headIndent` leaving a margin for a drawn label (the column's header).
- Caret rects, selection and hit-testing are the ordinary TextKit ones.

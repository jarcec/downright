# Spike — scrolling a table sideways on its own

Can one table row be laid out shifted left of the column, so a wide table can scroll
horizontally while the rest of the document stays put? Headless, no app bundle needed.

```sh
swiftc -O e1.swift -o e1
MODE=kern ./e1 120                  # negative kern on the row's first character
MODE=indent ./e1 120                # negative head indents
MODE=container WIDTH=huge ./e1 120  # NSTextContainer subclass shifting the line rectangle
MODE=container WIDTH=same ./e1 120  # … keeping the proposed width
TRACE=1 …                           # print every lineFragmentRect call
```

## Findings (macOS 27.0, Swift 6.3)

- **Negative kern** on the leading pipe moves the following glyphs by at most the pipe's
  own width: TextKit clamps a glyph's position at the line origin.
- **Negative `headIndent` / `firstLineHeadIndent`** are clamped to 0, and the paragraph
  starts wrapping although its line-break mode is `.byClipping`.
- **An `NSTextContainer` subclass overriding `lineFragmentRect(forProposedRect:…)`** and
  returning a rectangle whose x is `-shift` lays the row out shifted: caret rectangles
  and hit-testing follow exactly (a point on a visible glyph maps to its offset; glyphs
  scrolled out clamp to x = 0). Two caveats:
  - Overriding the hook at all takes TextKit 2 off the layout path that honours
    `.byClipping`: a row in a rectangle narrower than its text wraps. Returning a very
    wide rectangle for table rows keeps them on one line; the fragment clips the drawing.
  - `NSTextView` moves `textContainerOrigin` right by the negative usage bounds, which
    shifts every *other* paragraph instead. The view must pin the origin to its inset.

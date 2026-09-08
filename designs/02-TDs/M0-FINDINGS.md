# M0 Spike — Findings

**Date:** 2026-09-08
**Environment:** macOS 27.0 (26A5425a), Xcode 26.6, Swift 6.3.3, Apple silicon
**Code:** `spikes/m0-textkit2/` — headless, reproducible, no app bundle required
**Gates:** TRD §6 (rendering and concealment), §10 (performance), §11 (spike questions)

---

## Verdict

**The architecture is sound, and the mechanism is the opposite of what the TRD predicted.**

The TRD's *primary* approach — substituting a shorter display paragraph via
`NSTextContentStorage`'s delegate — is **rejected**. The TRD's *fallback* — keeping the
display string length-identical and rendering markers with zero advance width — is
**adopted**, and it turns out to be materially better than the design assumed: it removes
an entire subsystem (`ConcealmentMap`) from the design and makes clipboard fidelity free.

Proceed to M1. No unresolved architecture-breaking risk remains.

---

## Q1 — Can a substituted paragraph differ in length from its backing range?

**Yes, the API accepts it — and the result is silently incoherent.** This is the dangerous
outcome: no exception, no assertion, no log. Layout and navigation simply become wrong.

With a display string shorter than its backing range (`e3.swift`, variant D):

| Observation | Result |
|---|---|
| Layout fragments enumerated | **1 of 4** — enumeration terminates early |
| Caret moved one character forward from source offset 11 | lands on offset **55** (expected 12) |
| `textLayoutFragment(for:)` at a visible point | **nil** |
| Backing store integrity | intact (the one thing that did hold) |

Diagnosis: `elementRange` is reported in *source* coordinates while `rangeInElement` comes
back in *display* coordinates. Once those diverge, the layout manager's position arithmetic
desynchronises from the content manager's and the document walk falls apart.

**Consequence:** any design that deletes characters in the substitution hook is unbuildable.
That includes the approach the TRD named as primary.

## Q2 — Does the length-preserving approach work?

**Yes, completely.** Two length-preserving variants were tested; only one is viable.

| Strategy | Fragments | Caret walk from offset 11 | Hit test | Verdict |
|---|---|---|---|---|
| A · baseline, no substitution | 4/4 | `11,12,13,…,21` ✅ | correct | control |
| D · delete markers | 1/4 | `11,55,56,…` ❌ | nil ❌ | **rejected** |
| B · markers → zero-width space | 4/4 | `…17,18,21,22` ❌ (skips 19–20) | correct | **rejected** |
| C · markers keep chars, ~0 pt font | 4/4 | `11,12,13,…,21` ✅ | correct | **adopted** |

Variant B fails because `U+200B` joins adjacent characters into a single grapheme cluster,
so character-wise navigation steps over it — and it corrupts the copied text besides.

Variant C collapses width exactly as intended. Measured line widths:

| Paragraph | Baseline | Variant C |
|---|---|---|
| `Some **bold** text here.` | 149.8 pt | **127.5 pt** — the four `*` contribute ~0 |
| `# Heading one` (rendered 20 pt) | — | 118.3 pt, identical to a string with the marker genuinely removed |

## Q3 — Is caret and selection mapping correct?

**There is nothing to map.** Under variant C the display string and the source string have
identical character counts and identical indices, so the source↔display mapping is the
identity function. Caret navigation, hit-testing, and `NSTextSelectionNavigation` all
operate directly in source offsets with no translation layer.

**This deletes `ConcealmentMap` (TRD §6.4) from the design entirely** — the binary-search
run table, its invalidation, and its round-trip property tests are all unnecessary.

One cosmetic artifact, measured in `e5.swift`: consecutive offsets spanning a concealed run
share a caret x-position (offsets 0, 1, 2 all sit at x ≈ 0.00 where `# ` is hidden). Because
the reveal rule guarantees the caret's own paragraph is never concealed, this is unreachable
in normal editing.

## Q4 — Does invalidation stay local on a reveal toggle?

**Yes — exactly 2 paragraphs rebuilt, in 0.18 ms, independent of document size.** This is
precisely the budget TRD §6.6 demands, confirmed on a 10 MB document.

The trigger that works: mark the paragraph range edited inside an editing transaction —
`storage.performEditingTransaction { backing.edited(.editedAttributes, range: r, changeInLength: 0) }`
— which re-invokes the delegate for that paragraph only.

## Q5 — Performance

Measured with the concealment delegate active throughout (`e4.swift`):

| Operation | 1 MB | 10 MB | Budget (TRD §10) |
|---|---|---|---|
| Content storage construction | 0.2 ms | **1.6 ms** | — |
| Viewport layout (~1000 pt, 77 fragments) | 3.6 ms | **3.5 ms** | < 1 s to editable ✅ |
| Single-character edit + relayout | 0.42 ms | **0.40 ms** | < 8 ms ✅ |
| Reveal toggle (2 paragraphs) | 0.18 ms | **0.18 ms** | < 8 ms ✅ |

Layout cost is a function of the viewport, not the document — 1 MB and 10 MB are
indistinguishable. Every §10 budget is met with an order of magnitude of headroom.

**One hard limit found:** laying out a full 10 MB document takes **11.9 seconds**. Nothing
may ever trigger it. Concretely, scroll-bar proportions must come from estimated heights
rather than real layout, and "scroll to end" must not force intervening layout. This is a
new constraint on the viewport layer, recorded as risk R8.

## Q6 — Do composed features still work?

- **Soft wrapping** behaves normally around concealed runs; no degenerate breaks, no
  overflow (`e4.swift` E9).
- **Live `NSTextView`** binds to a custom `NSTextContentStorage`, reports
  `textLayoutManager != nil`, and typing edits the raw source correctly (`e5.swift`).
- **Clipboard fidelity is free.** Because the concealed characters are still *present* in
  the display string, `tv.string` and `attributedSubstring(forProposedRange:)` return raw
  Markdown. PRD §4's "copying any range yields raw Markdown source" needs no special code.

## Q7 — What did *not* work

**Concealing an entire line does not collapse its height.** A fully hidden fence line
(`` ```swift ``, every character at 0.01 pt including the newline) still occupies a
16 pt line fragment (`e4.swift` E8). Attributes alone cannot remove a line from the flow.

Not fatal — a custom `NSTextLayoutFragment` is already specified for code blocks (TRD §6.5)
and can force zero height — but it moves fence-line hiding from "free" to "requires a custom
fragment", which pulls that work forward into M3. Recorded as risk R9.

---

## Design changes required

| # | Change | Where |
|---|---|---|
| 1 | Zero-advance rendering becomes the primary mechanism; length-changing substitution is documented as rejected with evidence | TRD §6.2–6.3 |
| 2 | `ConcealmentMap` deleted from the design | TRD §6.4 |
| 3 | Full-document layout is a prohibited operation; viewport layer must use estimated heights | TRD §6.6, §10, R8 |
| 4 | Whole-line concealment requires a custom layout fragment | TRD §6.5, R9 |
| 5 | Clipboard fidelity requires no implementation | PRD §4 |

## Residual unknowns (not blocking M1)

- Zero-size fonts and VoiceOver: whether concealed runs are announced. Test in M2.
- Zero-size fonts and cursor-key *vertical* movement across differing line heights.
- Whether `0.01 pt` is the right constant, and whether `.foregroundColor: .clear` is needed
  alongside it or is redundant belt-and-braces.
- Behaviour under text-input contexts: IME/marked text over concealed runs.

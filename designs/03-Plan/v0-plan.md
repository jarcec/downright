# Downright v0 — Implementation Plan

**Date:** 2026-09-08
**Inputs:** `../02-TDs/PRD.md`, `../02-TDs/TRD.md`, `../02-TDs/M0-FINDINGS.md`
**Status:** Accepted 2026-09-08

---

## 1. What v0 is

The PRD defines milestones M0–M5 but not "v0". This plan defines it:

> **v0 is the build the author uses daily instead of Obsidian for opening `.md` files.**
> Sandboxed, signed with the development identity, installed in `/Applications`, driven by
> `downright FILE` from the shell. Not submitted to the App Store. Not shared.

That is PRD milestones **M1 + M2**, plus the sandbox validation that M0 could not perform,
plus just enough of M3 (code blocks, task checkboxes) that everyday LLM-output files render
properly. Everything else is explicitly deferred.

### In v0

| Area | v0 scope |
|---|---|
| Documents | Open, edit, save, autosave, Versions; byte-faithful round trip; external-change reload |
| CLI | `downright FILE...` fire-and-forget through Launch Services, on a **sandboxed** build |
| Hybrid rendering | Headings, bold/italic, strikethrough, inline code, links, bullet & ordered lists, task checkboxes (rendered + clickable), block quotes, thematic breaks, fenced & indented code blocks (no syntax highlighting), frontmatter (tinted, source shown) |
| Reveal | PRD §7.1 rule exactly: caret paragraph reveals; fences reveal as a unit; selection reveals all touched paragraphs |
| Dialect | GFM profile hard-coded |
| Editing | Smart list continuation, Tab/⇧Tab indent, ⌘B/⌘I/⌘K toggles, system find bar |
| Appearance | System light/dark, one built-in theme, fixed fonts |

### Deferred past v0

Tables as a grid (render as monospace source), images (needs the sandbox folder-grant UX),
syntax highlighting inside fences, dialect auto-detection and switching, footnotes,
preferences UI, themes, Homebrew formula (a script on `PATH` is enough for one user),
App Store submission, accessibility audit.

---

## 2. Repository layout

```
downright/
├── Package.swift                 # SPM workspace: MarkdownKit, DownrightEditor
├── Sources/
│   ├── MarkdownKit/              # pure Swift, zero AppKit — parser, model, dialect
│   └── DownrightEditor/          # AppKit — content storage delegate, decorations,
│                                 #   reveal policy, layout fragments, text view
├── Tests/
│   ├── MarkdownKitTests/         # spec suite, round-trip, incremental equivalence
│   └── DownrightEditorTests/     # reveal policy, decoration, invalidation counts
├── App/
│   ├── project.yml               # XcodeGen → Downright.xcodeproj (not committed)
│   ├── Downright/                # NSDocument app target, entitlements, Info.plist
│   └── DownrightUITests/
├── cli/
│   └── downright                 # the shim (shell)
├── spikes/                       # throwaway, kept for evidence
└── designs/
```

**Why two SPM targets and an app.** `MarkdownKit` must never import AppKit — that is what
lets the entire parser test suite run with `swift test` in seconds, on CI, without a
simulator or window server. `DownrightEditor` holds everything that touches TextKit but
nothing that touches windows or documents, so it too is testable headlessly (the M0 spike
proved TextKit 2 lays out fine without a window). The app target is thin: documents,
windows, menus, the CLI hand-off.

**Why XcodeGen.** The app needs an `.xcodeproj` for entitlements, signing and the App Store
later, and a hand-maintained project file is hostile to review and to tooling. `project.yml`
is ~40 lines of text; the `.xcodeproj` is generated and git-ignored. Requires
`brew install xcodegen`. Fallback if it proves awkward: commit a hand-made project.

---

## 3. Decisions this plan makes

Recorded here so they are not re-litigated mid-build. Each is reversible; none is free.

| # | Decision | Why |
|---|---|---|
| D1 | **UTF-16 offsets everywhere.** `MarkdownKit` parses `String.UTF16View` and reports `NSRange`-compatible offsets. | `NSTextStorage` is UTF-16. One offset space end to end removes an entire class of off-by-emoji bugs. |
| D2 | **Naive full-document parser first; incremental second, verified against it.** | The naive parser is simple to get right and becomes the oracle for the property test that guards the incremental one (TRD §12). Trying to write the incremental parser first means debugging two things at once. |
| D3 | **The shim `touch`es a nonexistent path before opening it.** | The shim runs unsandboxed in the user's shell; the app does not. Creating the empty file there lets Launch Services grant it normally and lets autosave handle the rest — no save panel, no untitled-buffer special case. Cost: an abandoned `downright new.md` leaves a 0-byte file. *Amends PRD §9/§10; see §8.* |
| D4 | **Same-length glyph substitution is allowed; count-changing substitution never is.** | M0 showed count changes break layout. But `-` → `•` is 1:1, and M0 also showed `NSTextView.string` reads the *backing* store, so copy fidelity survives. This gives real bullets and checkbox glyphs without custom drawing. Must be re-verified for grapheme behaviour in Phase 3 (ZWSP failed for exactly that reason). |
| D5 | **Custom `NSTextLayoutFragment`s are introduced in Phase 3, not later.** | Fence-line hiding (R9), code-block backgrounds, quote bars and thematic breaks all need them, and they are the one TextKit 2 mechanism M0 did not exercise. Earlier is cheaper. |
| D6 | **"Reveal All" toggle in the View menu from day one.** | Turns concealment off globally. Trivial to build, invaluable for debugging the decoration engine, and an escape hatch for the user when rendering is wrong. |
| D7 | **Development-signed, sandboxed from the first commit.** | The sandbox is a product decision with technical consequences (TRD §9). Building unsandboxed and "turning it on later" guarantees discovering those consequences at the worst time. |

---

## 4. Phases

Sizes are relative: **S** ≈ a focused session, **M** ≈ a few, **L** ≈ many, **XL** ≈ the
long pole. Phase 2 has no AppKit dependency and can proceed in parallel with Phases 0–1.

### Phase 0 — Gate: does the sandbox permit the CLI? (S)

Retires **TRD R6**, the highest open risk. Nothing else in the app is worth building until
this passes, because a failure changes the distribution decision.

1. XcodeGen project: single NSDocument app, `com.apple.security.app-sandbox` +
   `files.user-selected.read-write`, document types `.md`, `.markdown`, `.txt`;
   signed with the Apple Development identity. The document view is a plain `NSTextView`.
2. Install to `/Applications`. From Terminal, test and record each of:
   - `open -a Downright ~/x/existing.md` → does the app read the contents?
   - Edit, ⌘S → does the write succeed?
   - `touch new.md && open -a Downright new.md` (the D3 path) → opens and saves?
   - External atomic rewrite while open: `printf 'new' > t && mv t existing.md` → does the
     app still have access? Does `NSDocument`'s file-presenter machinery notice?
   - `![](sibling.png)`-style sibling read → confirm it is *denied* (calibrates R10).
3. Write results to `designs/02-TDs/R6-FINDINGS.md`.

**Exit:** the first three pass. If Launch Services does not grant access, **stop** and
reopen PRD OQ-5 — the App Store and `downright FILE` would be mutually exclusive.

### Phase 1 — Walking skeleton (M)

A real document app with no Markdown intelligence. Everything here is table stakes that
`NSDocument` mostly provides; the work is fidelity.

1. Repository layout from §2; `Package.swift` with empty `MarkdownKit` / `DownrightEditor`
   targets and one passing test each; GitHub Actions running `swift test` and
   `xcodebuild build` on a macOS runner.
2. `TextFileFormat` — encoding, BOM presence, dominant line ending, trailing-newline
   presence — detected on read, reapplied on write. Test: byte-identical round trip over a
   corpus including CRLF, BOM, no-trailing-newline, and mixed-ending files.
3. `MarkdownDocument: NSDocument` — read/write via `TextFileFormat`, autosave in place,
   Versions, external change → silent reload when unmodified, prompt when modified.
4. `MarkdownTextView: NSTextView` on TextKit 2 with our own `NSTextContentStorage` (the
   M0 wiring), every automatic substitution disabled, no rich-text paste.
5. `cli/downright`: resolve args against `$PWD`, `touch` missing files (D3), `open -a
   Downright` them, exit 0. `-n/--new`, `-v`, `-h`. Symlinked into `PATH` by hand for v0.
6. Window restoration, recent documents, standard Edit menu, system find bar.

**Exit:** open, edit, save any UTF-8 Markdown file with a byte-identical unmodified round
trip; `downright a.md b.md` from Terminal opens two windows on the sandboxed build.

### Phase 2 — MarkdownKit (XL — the long pole)

Pure Swift, headless, spec-driven. Can start on day one alongside Phases 0–1.

**2a. Model.** `Document → [Block]`, `Block` enum (paragraph, heading, thematicBreak,
codeBlock, htmlBlock, blockQuote, list/listItem, table, frontmatter, linkReferenceDefinition,
blankLine), each with `sourceRange: NSRange` and, where relevant, `markerRanges: [NSRange]`.
Leaf blocks own `[Inline]` — emphasis, strong, strikethrough, code, link, image, autolink,
hardBreak, text — each with its own `markerRanges`. This model *is* the contract with
`DownrightEditor`; design it for the decoration engine, not for HTML.

**2b. Block parser, naive.** Line-oriented CommonMark block algorithm: container matching,
lazy continuation, fence tracking, list-item indentation rules, setext detection, HTML block
start/end conditions, link reference definitions, frontmatter (only at offset 0), GFM table
detection (structure only — cells are not parsed in v0). Whole document, every call.

**2c. Inline parser.** The CommonMark delimiter-run algorithm for `*`/`_` emphasis, code
spans (backtick-run matching), links and images with the bracket stack, autolinks,
backslash escapes, entity passthrough, hard breaks, GFM strikethrough. This is where most
CommonMark subtlety lives; budget accordingly.

**2d. Spec harness.** A test-only `HTMLRenderer` over the model and a runner for the
CommonMark `spec.json` (≈650 examples) and the GFM extension examples. **Target for v0:
≥ 95% of CommonMark examples passing, every failure listed in `KNOWN-DIVERGENCES.md` with
a reason.** 100% is not a v0 goal; a known, documented gap is.

**2e. Round-trip invariant.** Property test: `parse(s)` covers `s` exactly — every
character of the source belongs to exactly one node's range, ranges nest properly, marker
ranges lie inside their node. This is what the decoration engine depends on.

**2f. Incremental block parser.** Given the previous `Document` and an edit
`(range, replacement)`: find the top-level block containing the edit start, reparse forward
from there, and stop at the first block boundary where the new parse re-synchronises with
the old (same block kind at the same source offset, adjusted for the delta). Fence toggles
naturally fail to resync and fall through to the end — correct, and rare. Inline parsing
reruns for changed leaf blocks only.

**2g. Equivalence property test.** Random document, random edit sequence:
`incremental(prev, edit) == naive(applied)` structurally. **This is the single most valuable
test in the project.** Run thousands of iterations in CI.

**Exit:** 2d target met; 2e and 2g green; naive parse of a 1 MB document under 50 ms and
incremental single-character edit under 1 ms (both measured, both recorded in the TRD §10
table).

### Phase 3 — Hybrid rendering (L)

Where the product becomes itself. Each element lands as its own commit with a test.

**3a. `RevealPolicy`** — pure function `(selection, Document) → Set<ParagraphID>` per TRD §7.
Exhaustive unit tests. Ten minutes of code, guarded forever.

**3b. `DecorationEngine`** — `(Document, revealedSet, Theme) → [ParagraphDecoration]` where
a decoration is `styleRuns`, `concealRuns`, `glyphSubstitutions` (D4), and a `blockKind`
for the fragment provider. Pure, testable, no TextKit.

**3c. `MarkdownContentStorageDelegate`** — the M0 hook. Applies a `ParagraphDecoration` to
the source paragraph, producing the display paragraph. Enforces, with a debug assertion,
**display length == source length** — the M0 lesson as a runtime invariant.
`Theme.concealedFont` and `.concealedColor` are the single named constants (TRD OQ-T7).

**3d. Wiring.** Text edit → `MarkdownKit` incremental update → invalidate exactly the
changed paragraphs. Selection change → `RevealPolicy` diff → invalidate exactly the
entering/leaving paragraphs (or constructs). **Debug assertion: a pure caret move never
invalidates more than 2 paragraphs unless a fence or table is involved.** This is the TRD
§6.6 budget as a test.

**3e. Inline elements**, in order: headings → strong/emphasis → inline code → links (`.link`
attribute for hover and click; scheme allow-list `http https mailto file`) → strikethrough.

**3f. Glyph substitution (D4).** `-`/`*`/`+` → `•`; `[ ]` → `☐` + 2 concealed, `[x]` → `☑` +
2 concealed. First task: confirm caret navigation is exact across substituted glyphs (the
ZWSP failure mode). Checkbox click: hit-test to the source range, replace `[ ]`↔`[x]` as
one undoable edit.

**3g. Custom layout fragments (D5).** `NSTextLayoutManagerDelegate` provides fragments by
`blockKind`: code block (background, padding, **zero-height fence lines — R9**), block quote
(left bar, indent), thematic break (rule, text concealed), frontmatter (tint). First task:
a five-line spike that a zero-height fragment lays out and scrolls correctly — this is the
one mechanism M0 did not touch.

**3h. Reveal-All toggle (D6)** and **Theme** with light/dark variants following the system.

**Exit:** every element in §1's "Hybrid rendering" row renders and reveals per PRD §7.2;
3d's invalidation assertion holds under an automated caret-walk over a large document;
the app is usable for reading real files.

### Phase 4 — Daily-use polish (M)

The difference between "works" and "I stopped opening Obsidian."

1. Return in a list item continues the list; Return on an empty item ends it. Tab / ⇧Tab
   indent and outdent, preserving marker style.
2. ⌘B, ⌘I, ⌘K (wrap selection as link; if the clipboard holds a URL, use it), ⌘⇧K inline
   code — each an undoable toggle that removes markers if already present.
3. Paste of a URL over a selection → `[selection](url)`. All other paste is literal.
4. Typing performance pass with the parser attached: profile against TRD §10, fix the top
   three hot spots, record measurements.
5. Dogfood punch-list: one week of real use, every irritation logged as an issue.

**Exit:** the author's stated bar from PRD §12 — two weeks of daily use without reaching
for Obsidian.

### Phase 5 — v0 cut (S)

- Tag `v0.0.0`. Development-signed build in `/Applications`, shim on `PATH`.
- Update TRD §10 with measured end-to-end numbers; retire or re-rate R3, R8, R9, R10 based
  on what Phase 3 actually found.
- Write `designs/04-v1/` seed: what v0 taught, what v1 must fix first.

---

## 5. Sequencing and the critical path

```
Phase 0 (gate) ──► Phase 1 (skeleton) ──► Phase 3 (rendering) ──► Phase 4 ──► Phase 5
                                             ▲
Phase 2 (MarkdownKit, parallel) ─────────────┘  needs 2a–2e; 2f–2g can land during 3
```

- **Phase 0 blocks everything.** Half a day; do it first.
- **Phase 2 is the long pole** and has zero AppKit dependency — start it in parallel with
  Phases 0–1. Phase 3 needs only the *naive* parser and the model (2a–2e); the incremental
  parser (2f–2g) can land while 3e–3g are underway, behind the same model contract.
- Within Phase 3, 3a–3d are the spine; 3e–3h are independent and can be reordered by
  whatever the dogfood files need most.

---

## 6. Testing, by layer

| Layer | Runs where | What |
|---|---|---|
| `MarkdownKit` | `swift test`, seconds, CI | Spec harness (2d), coverage invariant (2e), incremental ≡ naive (2g), perf |
| `DownrightEditor` | `swift test`, headless TextKit (as in M0) | `RevealPolicy` exhaustive; decoration length-invariant; invalidation-count assertion on caret walks; glyph-substitution caret-exactness |
| App | `xcodebuild test`, XCUITest, slower | Round-trip byte fidelity over a corpus; CLI opens files on a sandboxed build; external-change reload |
| Manual | dogfood | Everything that is actually about feel |

Rule of thumb: if a bug is reproducible in `MarkdownKit` or `DownrightEditor`, it gets a
headless test, not a UI test.

---

## 7. Risks specific to this plan

| Risk | Signal | Response |
|---|---|---|
| Phase 0 fails | Sandboxed app cannot read a CLI-opened file | Stop. Reopen distribution decision before writing any editor code |
| Inline parser eats the schedule | 2d stalls below 90% | Ship v0 with the gap documented; emphasis edge cases are rare in real files and the fallback is literal text, not corruption |
| Zero-height fragments misbehave | 3g spike shows scroll or hit-test glitches | Fence lines render as dimmed 1-line source instead; revisit post-v0 |
| Same-length glyph substitution breaks caret math | 3f spike shows skipped offsets | Style the raw marker instead of substituting; bullets via fragment drawing post-v0 |
| Naive parser too slow to use as the interim | > 8 ms on typical dogfood files | Pull 2f forward; the property test is already designed |

---

## 8. Document amendments this plan implies

**Applied 2026-09-08.** Kept here as a record of what changed and why:

- **PRD §9, §10 and TRD §9** — nonexistent-path behaviour: the shim creates the file (D3)
  instead of the app opening an untitled named buffer with a save panel.
- **TRD §6.2** — add D4: same-length glyph substitution is permitted; the invariant is
  *character count*, not *character identity*.
- **PRD §13** — insert "v0" as a named point between M2 and M3 with the scope in §1 here.

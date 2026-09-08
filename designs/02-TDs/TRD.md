# Downright — Technical Requirements Document

**Status:** Draft v1
**Date:** 2026-09-08
**Author:** jarcec (with Claude)
**Companion:** `PRD.md` in this directory
**Spike results:** `M0-FINDINGS.md` — §6, §9, §10 and §11 below reflect measured results, not estimates

---

## 1. Scope

This document specifies how Downright is built: platform targets, architecture, the
rendering mechanism, the parser, the CLI, performance budgets, testing strategy, and the
technical risks that must be retired before committing to the design.

The one requirement that shapes everything else: **rendered Markdown and raw Markdown
share a single text view, and the backing store is always the unmodified source.**

## 2. Platform and toolchain

| Item | Decision | Notes |
|---|---|---|
| Minimum OS | macOS 14 Sonoma | TextKit 2 is mature here; revisit if a needed API is 15+ only (OQ-T1) |
| Architecture | arm64 + x86_64 universal | |
| Language | Swift 6, strict concurrency enabled | |
| UI framework | **AppKit** for the editor and document layer; SwiftUI for preferences, inspectors, and secondary chrome | SwiftUI's `TextEditor` cannot express this rendering model |
| Text engine | **TextKit 2** (`NSTextLayoutManager` / `NSTextContentStorage`) | TextKit 1 is legacy; TextKit 2's fragment model is what makes block widgets tractable |
| Dependencies | Minimal, vendored or SPM, no runtime frameworks that pull in a browser engine | |
| Distribution | **Mac App Store** (sandboxed) | Decided; see §9 for the consequences |

**Hard constraint:** no `WKWebView`, no JavaScriptCore, no Electron, no CodeMirror. The
editing surface is `NSTextView`.

## 3. Architecture overview

```
┌──────────────────────────────────────────────────────────────┐
│ DocumentController / MarkdownDocument (NSDocument)            │
│   file I/O, encoding & line-ending fidelity, autosave,        │
│   external-change detection, undo manager                     │
└───────────────┬──────────────────────────────────────────────┘
                │  raw source (String, single source of truth)
┌───────────────▼──────────────────────────────────────────────┐
│ SourceStore  (NSTextContentStorage + NSTextStorage)           │
│   INVARIANT: contents == bytes that will be written to disk   │
└───────────────┬──────────────────────────────────────────────┘
                │  edit deltas
┌───────────────▼──────────────────────────────────────────────┐
│ IncrementalParser                                             │
│   block structure + inline spans, with exact source ranges    │
│   for every syntactic marker                                  │
└───────────────┬──────────────────────────────────────────────┘
                │  node tree + marker ranges
┌───────────────▼──────────────────────────────────────────────┐
│ DecorationEngine        ← RevealPolicy (caret/selection)      │
│   per paragraph: [style spans], [conceal ranges], [widgets]   │
└───────────────┬──────────────────────────────────────────────┘
                │  decorations
┌───────────────▼──────────────────────────────────────────────┐
│ RenderLayer                                                   │
│   NSTextContentStorage delegate → display attributes          │
│   custom NSTextLayoutFragment (code blocks, quotes, rules,    │
│   tables) · NSTextAttachmentViewProvider (checkbox, image)    │
│   display string is LENGTH-IDENTICAL to source — no mapping   │
└──────────────────────────────────────────────────────────────┘
```

Data flows one way: **edit → parse → decorate → render.** The render layer never writes
back into the store. The only components that mutate text are user editing commands
(including the task-list checkbox), and they do so through the document's undo manager.

## 4. Text storage and the core invariant

- The backing `NSTextStorage` holds the raw Markdown, character for character.
- Styling and concealment are **display-only**: they are computed on the way to layout and
  are never written into the backing store's attributes as semantic state.
- Consequences that must hold, and be tested: opening a file and saving it without editing
  produces a byte-identical file; every marker the user typed survives a round trip;
  copying any range yields raw Markdown source, never rendered text.
- macOS text substitutions (smart quotes, smart dashes, text replacement) are **disabled**
  on the text view. They corrupt Markdown and violate the invariant.

## 5. Parsing

### 5.1 Requirements

- **Incremental.** An edit reparses the affected block(s), not the document. Editing one
  character in a 10 MB file must not trigger a full reparse.
- **Range-exact.** Every syntactic marker needs its precise source range — the `##` and the
  space after it, each `*`, each backtick, the `[`, `]`, `(`, `)` of a link. Coarse
  node-level ranges are insufficient; concealment operates on marker ranges.
- **Error-tolerant.** Half-typed syntax is the normal state while typing. Unparseable input
  degrades to literal text, never to a rendering glitch or a stale tree.
- **Configurable by dialect** (PRD §8) — the enabled rule set is a parameter, not a
  compile-time constant.

### 5.2 Options

| Option | Incremental | Range-exact markers | Dialect-configurable | Risk |
|---|---|---|---|---|
| A. `swift-markdown` (cmark-gfm) | No — whole-document AST | Partial | Limited | Wrong shape for a live editor |
| B. tree-sitter-markdown via C interop | Yes, native | Yes | Grammar-level only | Markdown grammars are notoriously awkward; two-pass block/inline split |
| C. Custom line-oriented incremental parser | Yes, by construction | Yes, by design | Yes, cleanly | We own all the correctness work |

**Recommendation: C, a custom parser, with cmark-gfm used as a test oracle (§12).**

Rationale: Markdown block structure is line-oriented, which makes incremental block
parsing genuinely tractable — an edit invalidates the containing block and, at worst, the
blocks adjacent to it, with a "did the block structure change?" check to widen the dirty
range. Inline parsing is then per-paragraph and cheap enough to redo wholesale on the
paragraphs that changed. Both of Downright's distinguishing requirements — exact marker
ranges and runtime-selectable dialects — are first-class in a parser we own and awkward in
one we don't. Option B remains the fallback if the custom parser's correctness cost proves
higher than estimated during M0/M2.

### 5.3 Shape

```
Block pass   : source lines → block tree (containers: quote, list; leaves: para,
               heading, fence, html, table, thematic break, frontmatter)
               Incremental: dirty line range → containing block → reparse block ±1
Inline pass  : per leaf block → spans (emph, strong, code, link, image, strike, ...)
               with a MarkerRange list per span
```

Both passes run synchronously on the main actor for small edits (the common case, and the
only way to hit the keystroke budget). Documents above a size threshold move the block
pass to a background actor with a coalesced main-actor apply.

M0 measured the *layout* half of the keystroke budget at 0.40 ms on a 10 MB document,
leaving roughly 7.5 ms of the 8 ms frame for parse and decoration. The background threshold
should therefore be set once the parser exists and can be measured against that headroom —
it is not needed for M1.

## 6. Rendering and concealment — the crux

**Resolved by the M0 spike.** The mechanism below is measured, not proposed; see
`M0-FINDINGS.md` for evidence. The conclusion inverted this section's original ordering.

### 6.1 The requirement

For a concealed paragraph, the text view must display glyphs for the content characters
and *nothing* for the marker characters, while the backing store still contains both.

### 6.2 The mechanism — length-preserving zero-advance rendering

`NSTextContentStorage` exposes a delegate hook supplying the `NSTextParagraph` used for
layout for a given backing range. Downright uses it, with one binding rule:

> **The returned display paragraph must have exactly the same character count as its
> backing range.** Markers are concealed by rendering them at zero advance width, never by
> removing them.

Implementation: tag marker ranges with a custom `.downrightConcealed` attribute for the
decoration layer's own bookkeeping, and render them with a ~0 pt font (plus a clear
foreground colour). Content characters carry their real styling. Because the reveal rule
(PRD §7.1) is paragraph-scoped, reveal state is simply a per-paragraph input to this hook.

**The invariant is character *count*, not character *identity*.** Replacing a character with
a different single character is permitted — `-` → `•` for bullets, `[ ]` → `☐` plus two
concealed characters for a checkbox — because the layout manager's position arithmetic only
depends on length, and `NSTextView.string` and copy read from the backing store, so the
substituted glyph never leaks into the clipboard. Two constraints apply: the substitute must
be a single UTF-16 code unit with no combining behaviour (zero-width space failed precisely
because it forms grapheme clusters with its neighbours, §6.3), and the decoration layer must
assert `display.length == source.length` in debug builds on every paragraph it produces.
(Plan decision D4.)

Measured behaviour: markers contribute no measurable width (a `Some **bold** text here.`
line renders 127.5 pt against a 149.8 pt unconcealed baseline), soft wrapping is unaffected,
and the backing store stays pristine.

### 6.3 Rejected: length-changing substitution

Deleting marker characters in the substitution hook — this document's original primary
approach — **does not work, and fails silently.** The API accepts a shorter display string
without error, then produces incoherent layout: fragment enumeration terminates after the
first paragraph, one-character caret movement jumps by 44 characters, and hit-testing
returns nil. The cause is that `elementRange` is reported in source coordinates while
`rangeInElement` is reported in display coordinates; once they diverge the layout manager
desynchronises from the content manager.

Replacing markers with zero-width spaces preserves length but is also rejected: `U+200B`
forms grapheme clusters with adjacent characters, so caret navigation skips positions, and
the substituted characters would corrupt copied text.

### 6.4 Index mapping — not required

Because the display string is length-identical to the source, **source and display indices
are the same index.** Caret navigation, hit-testing and `NSTextSelectionNavigation` operate
directly in source offsets with no translation.

The `ConcealmentMap` this document previously specified — the run table, its invalidation,
its round-trip property tests — is deleted from the design. This is the single largest
simplification the spike produced.

Two consequences worth recording:

- **Clipboard fidelity is free.** The concealed characters are still present in the display
  string, so `NSTextView.string` and `attributedSubstring(forProposedRange:)` already return
  raw Markdown. PRD §4's copy requirement needs no implementation.
- **Caret x-positions collapse across a concealed run** (offsets `0`, `1`, `2` all sit at
  x ≈ 0 where `# ` is hidden). Unreachable in practice: the reveal rule guarantees the
  caret's paragraph is never concealed.

### 6.5 Block widgets

Block-level constructs that need more than character attributes are drawn by
`NSTextLayoutFragment` subclasses, which own their own geometry and drawing:

- Fenced/indented code block: background fill, padding, corner radius, language label.
  **Also responsible for collapsing the fence lines to zero height** — attributes alone
  cannot remove a line from the flow (a fully concealed `` ``` `` line still occupies its
  full 16 pt fragment). See risk R9.
- Block quote: left rule, indent, background tint.
- Thematic break: a rule.
- Table: a grid with cell rules and column alignment (M4; see PRD OQ-2).
- Frontmatter: tinted container with a disclosure control.

Interactive inline widgets use `NSTextAttachment` + `NSTextAttachmentViewProvider`:

- Task-list checkbox — clicking it performs an undoable edit of the `[ ]`/`[x]` characters.
- Image — an `NSImageView`-backed provider with an async, cached, size-capped loader;
  local files only by default (PRD §7.3).

### 6.6 Invalidation

A caret move invalidates exactly two paragraphs: the one being left (now conceals) and the
one being entered (now reveals). Multi-line constructs invalidate the construct's range.
Nothing else re-lays out. A full-document relayout on cursor movement is a defect, not a
performance issue.

Measured: a reveal toggle rebuilds exactly 2 paragraphs in 0.18 ms, independent of document
size. The trigger is a zero-length attribute edit inside an editing transaction —
`performEditingTransaction { backing.edited(.editedAttributes, range: r, changeInLength: 0) }`
— which re-invokes the delegate for that paragraph alone.

**Prohibited operation.** Laying out a full 10 MB document takes ~11.9 s. Nothing may ever
trigger it: scroll-bar proportions must derive from *estimated* line heights, and
scroll-to-end must not force layout of the intervening document. See risk R8.

### 6.7 Syntax highlighting inside code fences

Pluggable `CodeHighlighter` protocol keyed by the fence's info string. v1 ships a small
regex/state-machine tokenizer covering the languages that actually appear in this
workflow's files — Swift, Python, JS/TS, JSON, YAML, shell, SQL, Markdown, diff — with
unknown languages rendered as plain monospace. Tree-sitter grammars are a post-v1 upgrade
behind the same protocol.

## 7. Reveal policy

```
RevealPolicy:
  input:  selection (NSTextRange), block tree
  output: Set<ParagraphID> to display as raw source

  rules:
    1. every paragraph intersecting the selection reveals
    2. if a revealed paragraph is inside a fenced code block or a table,
       the entire construct reveals
    3. everything else conceals
```

The policy is a pure function of selection and block structure, which makes it directly
unit-testable and keeps reveal behavior from drifting as features are added.

## 8. Document layer

- `MarkdownDocument: NSDocument` provides autosave-in-place, Versions, restoration, and
  the undo manager for free — significant behavior we do not implement ourselves.
- **Encoding:** UTF-8 assumed; BOM detected and preserved; invalid sequences surface a
  clear error rather than lossy substitution. Non-UTF-8 files are detected and opened
  read-only with a warning in v1.
- **Line endings:** detected on read, preserved on write; mixed endings are preserved
  as-is, not normalized.
- **Final newline:** presence or absence is preserved.
- **Writes:** atomic (write to temp, `rename`), preserving file permissions and extended
  attributes.
- **External changes:** an `FSEvents`/`DispatchSource` watch per open document. Unmodified
  documents reload silently (essential when an LLM tool is editing the file you have open);
  modified documents prompt with a clear choice and never silently discard either side.

## 9. Command line interface

**Distribution is the Mac App Store**, which means the app is sandboxed
(`com.apple.security.app-sandbox`). That is a product decision; this section specifies how
the CLI works within it and what it costs.

**Shape.** A small shim script/binary that resolves each argument to an absolute path
against `$PWD` and hands the paths to the app via Launch Services
(`NSWorkspace.open(_:withApplicationAt:configuration:)` or `open -a`), then exits 0
immediately without waiting for any window. Custom URL schemes are avoided: they mangle
paths and add a registration for no benefit.

**Why Launch Services specifically.** A sandboxed app cannot open an arbitrary path just
because a string arrives on its doorstep. It *can* open a document that Launch Services
hands it, because Launch Services issues a sandbox extension for that file as part of the
user-intent chain — the same mechanism that lets a sandboxed editor open a file
double-clicked in Finder. Routing the CLI through Launch Services rather than argv is
therefore not a stylistic choice; it is the only thing that makes `downright FILE` work at
all under the sandbox. **This must be validated against a real signed sandboxed build early
in M1** (risk R6) — the spike did not cover it.

**Installing the shim.** A sandboxed app cannot write to `/usr/local/bin`, so it cannot
install its own CLI. Options, in preference order:

1. A **Homebrew formula for the shim alone** (`brew install downright-cli`) — a few lines of
   shell, versioned independently of the app, no entitlement needed. Preferred.
2. First-run UI that shows the exact one-line command for the user to paste.
3. A user-selected install location via `NSSavePanel`, which grants write access to that
   directory. Works, but is a strange experience for installing a CLI.

Note that a Homebrew *cask* for the app itself is not available: casks cannot install Mac
App Store applications.

**Costs of the sandbox** — each of these is a real, accepted consequence of choosing the
App Store:

| Consequence | Effect | Mitigation |
|---|---|---|
| Sibling files are not granted | Relative-path images (`![](img/a.png)`) fail to load: access is granted for the *document*, not its directory | Detect the denial and offer a one-time "grant access to this folder" `NSOpenPanel`, persisted as a security-scoped bookmark |
| Nonexistent paths cannot be opened | Launch Services cannot grant a file that does not exist | The shim, which runs unsandboxed in the shell, `touch`es the file first and then opens it normally (plan decision D3). The app never sees this case |
| Atomic external rewrites may revoke access | Sandbox extensions are path-based; an external tool that writes-temp-then-renames can invalidate the grant — and LLM tooling writes atomically, so this is the *common* case, not an edge case | Re-acquire via bookmark on write failure; verify behaviour in M1 |
| No Homebrew cask, no direct download | Update cadence and beta distribution are bound to App Review | TestFlight for macOS covers betas |

**Exit codes:** 0 on successful hand-off; 1 on usage error; 2 if the app cannot be located.

## 10. Performance budgets

| Operation | Budget | M0 measurement (layout only) | Enforcement |
|---|---|---|---|
| Keystroke → parse → decorate → paint (1 MB doc) | < 8 ms | 0.42 ms | Automated benchmark in CI |
| Caret move → reveal repaint | < 8 ms, ≤ 2 paragraphs invalidated | 0.18 ms, exactly 2 | Assert on invalidation count |
| Open 10 MB file → editable | < 1 s | 1.6 ms build + 3.5 ms viewport | Benchmark |
| Full reparse, 10 MB | < 2 s | not yet measured (no parser) | Benchmark (should never run interactively) |
| Idle CPU with a document open | ~0% | — | No polling timers; event-driven only |
| Scrolling a 10 MB document | 120 fps sustained | viewport layout is O(viewport), not O(document) | Only visible fragments laid out |

The measured column is the TextKit 2 layer alone, with concealment active but no parser
attached. It establishes that roughly 7.5 ms of each 8 ms frame remains available for
parsing and decoration.

Three structural rules protect these: **never reparse the whole document in response to an
edit**, **never re-lay-out the whole document in response to a caret move**, and **never
lay out the whole document at all** — a full 10 MB layout costs ~11.9 s (R8).

## 11. M0 spike — COMPLETE

Run 2026-09-08 on macOS 27.0 / Xcode 26.6 / Swift 6.3.3. Code in `spikes/m0-textkit2/`,
full write-up in `M0-FINDINGS.md`. **Verdict: architecture sound, proceed to M1.**

| # | Question | Answer |
|---|---|---|
| 1 | Can substitution change a paragraph's length? | Accepted by the API, but silently breaks layout, navigation and hit-testing. **Rejected** (§6.3) |
| 2 | Does caret/hit-testing work through a mapping layer? | **No mapping layer is needed** — length-preserving concealment makes source and display indices identical (§6.4) |
| 3 | Does a reveal invalidate only that paragraph? | Yes — exactly 2 paragraphs, 0.18 ms, size-independent |
| 4 | Does a 10 MB document meet budget? | Yes, with ~20× headroom on every interactive operation. Full-document layout (11.9 s) must never be triggered — new constraint R8 |
| 5 | Do custom fragments/attachments compose? | Not yet exercised. Deferred to M3; the mechanism is attribute-based so no conflict is expected |

**Newly discovered, not previously anticipated:** attributes alone cannot collapse a line's
height, so hiding whole lines (code fences) requires a custom layout fragment (R9).

The one question the spike did *not* answer, because it needs a signed sandboxed build:
whether Launch Services grants file access to a sandboxed app for a CLI-delivered path
(§9, R6). **This is now the highest-priority open risk and must be settled in M1.**

## 12. Testing strategy

- **Golden corpus.** The CommonMark and GFM spec suites, parsed by Downright and by
  cmark-gfm, compared for structural agreement. Divergences must be deliberate and recorded.
- **Round-trip invariant.** Property test: for any input, `open → save` is byte-identical.
  Run over the spec corpus, over the repo's own Markdown, and over fuzzer output.
- **Incremental-parser equivalence.** Property test: for a random document and a random
  edit sequence, the incremental parse tree equals the from-scratch parse tree. This is the
  single highest-value test in the project — it is where an incremental parser's bugs live.
- **ConcealmentMap round-trip.** `sourceIndex(displayIndex(i)) == i` for all valid `i`.
- **RevealPolicy unit tests.** Pure function, exhaustively testable.
- **Caret behavior UI tests.** Click, arrow, word-jump, and selection across concealed
  paragraphs; the "caret never lands inside a concealed run" invariant.
- **Performance regression tests** in CI against the §10 budgets.
- **Accessibility.** VoiceOver must read the rendered content with structure (heading
  levels, list membership, link targets) and never announce concealed markers as content.

## 13. Risks

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | ~~Concealment mechanism does not work in TextKit 2~~ | — | **Retired by M0.** Length-preserving zero-advance rendering verified end-to-end |
| R2 | Custom incremental parser is a larger correctness burden than estimated | Schedule | cmark-gfm oracle + equivalence property tests; tree-sitter fallback (§5.2 B) |
| R3 | Caret/selection edge cases feel subtly broken | Kills the product's core value | Largely retired: identity index mapping removes the whole class. Residual: VoiceOver and IME over concealed runs, untested |
| R4 | Table live-editing proves impractical | Feature cut | Prototype in M4; documented fallback to aligned pipe source (PRD OQ-2) |
| R5 | TextKit 2 performance on very large documents | Perf targets missed | Measured in M0, before commitment |
| R6 | **Launch Services does not grant sandboxed file access for CLI-delivered paths** | Kills `downright FILE`, the product's second pillar | **Highest open risk.** Validate with a signed sandboxed build in the first week of M1, before any editor work. If it fails, the choice is App Store *or* the CLI — not both |
| R8 | Full-document layout (11.9 s at 10 MB) triggered accidentally | App hangs on large files | Estimated heights for scroll metrics; assert in debug builds that full layout is never requested |
| R9 | Whole-line concealment needs a custom layout fragment | Pulls M3 work forward | Known and scoped; the fragment is already required for code-block backgrounds |
| R10 | Sandbox blocks relative-path images and atomic-rewrite reload | Degrades two everyday workflows | Security-scoped bookmarks with a clear one-time grant; verify against atomic writers in M1 |
| R7 | Scope creep toward a vault/PKM app | Loses the product's reason to exist | PRD §5 non-goals treated as binding |

## 14. Open questions

- **OQ-T1 — Minimum OS.** macOS 14 vs. 15. The spike used only APIs available since
  macOS 13, so macOS 14 remains viable; confirm once custom layout fragments are in.
- **OQ-T2 — Parser choice.** Custom (recommended) vs. tree-sitter. Revisit at the end of M2
  with real correctness data rather than estimates.
- ~~**OQ-T3 — Distribution.**~~ **Resolved: Mac App Store**, sandboxed. Consequences
  accepted and enumerated in §9; contingent on R6.
- **OQ-T4 — Threading threshold.** Document size above which block parsing moves off the
  main actor. M0 showed layout uses <0.5 ms of the frame, so this is a parser-side decision
  to be measured in M2 rather than guessed now.
- **OQ-T5 — Undo granularity.** Whether marker-toggling commands (⌘B, checkbox) coalesce
  with adjacent typing into one undo step, or always stand alone.
- **OQ-T6 — Dialect override persistence.** Per-path app state is specified (PRD §8), but
  the store's location and its behavior when files are moved or renamed needs a decision.
- **OQ-T7 — Concealment constant.** Is `0.01 pt` the right hidden-font size, and is
  `.foregroundColor: .clear` necessary alongside it or redundant? Trivial to settle, but it
  should be one named constant with a comment rather than a magic number in three places.

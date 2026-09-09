# Downright — Product Requirements Document

**Status:** Draft v1
**Date:** 2026-09-08
**Author:** jarcec (with Claude)
**Source:** `designs/01-idea/rough-idea.md`
**Related:** `TRD.md` (technical design) · `M0-FINDINGS.md` (feasibility spike, complete)

---

## 1. Summary

Downright is a native macOS Markdown editor built around a single editing surface that
renders Markdown in place while revealing the raw syntax on the line the caret occupies.
It opens files, not vaults, and it is launchable from the terminal as `downright FILE`.

It is a *writing and reading tool for people whose primary working format is Markdown* —
in 2026 that increasingly means people whose primary interface to LLMs is Markdown files.

## 2. Problem

Markdown files have become a primary working surface: prompts, plans, notes, specs, LLM
output. The tools available on macOS each miss in a different direction:

- **Split-pane editors** (source left, preview right) force a context switch and waste
  half the window. You read in one place and write in another.
- **Raw text editors** show syntax noise permanently; long documents are unpleasant to read.
- **Fully-rendered WYSIWYG editors** hide the source entirely, so you lose the ability to
  reason about and correct the actual Markdown — which matters when the file is an
  artifact consumed by something else (a tool, a repo, an LLM).
- **Obsidian's hybrid "Live Preview" mode solves this correctly**, but Obsidian is
  vault-first, Electron-based, and not driven from a shell.

There is no native, file-first, CLI-invokable macOS editor with Obsidian's hybrid editing
model. That is the hole Downright fills.

## 3. Target user

A developer or technical writer who:

- Lives in a terminal and in Markdown files simultaneously.
- Opens files by path, ad hoc, from many different directories — not from one notes vault.
- Wants rendered reading comfort without losing sight of, or control over, the source.
- Values native app behavior: instant launch, real windows and menus, low memory, no
  browser engine in the process.

Explicitly *not* the target: someone looking for a personal knowledge management system,
a note graph, or a publishing pipeline.

## 4. Goals

| # | Goal |
|---|------|
| G1 | Hybrid editing: rendered Markdown, with source markers revealed on the caret's line. |
| G2 | The file on disk is always exactly what the user typed — byte-faithful, no rewriting. |
| G3 | `downright FILE` opens the file in the app and returns immediately. |
| G4 | Native implementation: AppKit/TextKit, no web view, no embedded browser engine. |
| G5 | Broad Markdown dialect support with sensible auto-detection and a manual override. |
| G6 | File-first document model: one file per window, no vault or workspace concept. |
| G7 | Feels instantaneous — launch, open, and keystroke latency indistinguishable from a plain text editor. |

## 5. Non-goals (v1)

- Wikilinks (`[[...]]`), backlinks, graph view, transclusion, tags-as-navigation.
- Vaults, workspaces, folder indexing, cross-file search.
- Sync, sharing, collaboration, version history beyond the filesystem's.
- Publishing/export to PDF, HTML, DOCX. *(Post-v1 candidate; not v1.)*
- A plugin/extension runtime.
- A separate read-only preview mode — **live editing is the only mode**.
- iOS/iPadOS. Windows/Linux. Ever, for the latter two.
- Being a general-purpose code editor.

## 6. Product principles

1. **The text is the truth.** The document model is the raw Markdown string. Rendering is
   a lens over it, never a replacement for it. Nothing is ever silently rewritten — no
   smart quotes, no marker normalization, no reflowing, no reordering. Concealed syntax is
   still *present* in the rendered text, merely drawn at zero width, so copying any range
   yields real Markdown source (see `M0-FINDINGS.md` Q3).
2. **One surface.** There is no preview pane and no mode switch. What you read is what
   you edit.
3. **Reveal is predictable.** The rule for when raw syntax appears must be learnable in
   thirty seconds and never surprising.
4. **Files, not a system.** Downright opens a path. It does not want to own your notes.
5. **Native means native.** Behaves like a Mac document app: NSDocument semantics,
   autosave, versions, standard keybindings, full keyboard access, VoiceOver.

## 7. Core experience: the hybrid editing model

### 7.1 The reveal rule

> **The paragraph containing the caret is displayed as raw Markdown source. Every other
> paragraph is displayed rendered, with its syntax markers concealed.**

"Paragraph" here means one logical line of the source (a hard-wrapped line as stored in
the file), not a soft-wrapped visual line.

Two refinements:

- **Multi-line constructs reveal as a unit** where partial reveal would be incoherent:
  a fenced code block reveals its opening and closing fence whenever the caret is anywhere
  inside it; a table reveals its full pipe/delimiter source whenever the caret is in any of
  its rows.
- **Selections reveal every paragraph they intersect.** A non-empty selection reveals all
  touched paragraphs, so you can see exactly what you are about to cut or replace.

This rule has a valuable consequence: **concealment never applies to the caret's own
paragraph.** Within the line you are editing, displayed text and source text are identical,
so caret movement, word jumps, and selection inside the active line behave exactly like a
plain text editor. There is no class of "caret got stuck in a hidden marker" bugs.

*Alternative considered:* per-span reveal (reveal only the emphasis span the caret is
inside, not the whole line). Rejected for v1 as harder to predict and much harder to
implement correctly; see Open Question OQ-1.

### 7.2 Element behavior

| Element | Rendered (caret elsewhere) | Revealed (caret in paragraph) |
|---|---|---|
| ATX heading `## H` | Heading typography, marker hidden | Full source, heading typography retained |
| Setext heading | Heading typography, underline row hidden | Full source incl. underline row |
| Bold / italic / bold-italic | Styled, markers hidden | Markers shown, styling retained |
| Strikethrough `~~x~~` | Struck, markers hidden | Markers shown |
| Highlight `==x==` (extended) | Highlighted, markers hidden | Markers shown |
| Inline code `` `x` `` | Monospace + subtle background, backticks hidden | Backticks shown |
| Inline link `[t](url)` | Link text only, link-styled; URL on hover | Full `[t](url)` source |
| Reference link + definition | Link text only; definition line rendered dimmed | Full source |
| Bare URL / autolink | Link-styled and clickable | Unchanged (no markers to hide) |
| Image `![a](p)` | Inline image, sized to fit width | Full source, image hidden |
| Bullet list | Typographic bullet, hanging indent | Raw `-`/`*`/`+` marker |
| Ordered list | Number + hanging indent | Raw `1.` source |
| Task list `- [ ]` | Interactive checkbox (clickable) | Raw `- [ ]` source |
| Block quote | Left rule + indent, `>` hidden | `>` shown |
| Fenced code block | Monospace block, background, syntax-highlighted, fences hidden | Fences shown; highlighting retained |
| Indented code block | Monospace block with background | Unchanged |
| Thematic break `---` | Horizontal rule | Raw source |
| Table (GFM) | Aligned grid with rules | Raw pipe source |
| YAML frontmatter | Tinted, collapsible metadata block | Raw source |
| Footnote ref/def | Superscript marker; definition dimmed at position | Raw source |
| Raw HTML block/inline | Passed through as literal source, monospace, dimmed | Same |
| Hard line break (2 spaces) | Visible break; trailing spaces marked with a faint glyph | Raw |

Rendering never changes the source. Toggling a task-list checkbox is the one interaction
that edits text, and it does so as a normal undoable edit of the `[ ]`/`[x]` characters.

### 7.3 Interaction details

- **Clicking into a concealed paragraph** places the caret at the source position
  corresponding to the clicked glyph, then reveals the paragraph. The caret does not jump
  when the line re-lays out.
- **Vertical arrow movement** preserves horizontal position visually, as in any editor.
- **Links** open in the default browser on ⌘-click, and on plain click when the caret is
  not already in that paragraph. Only `http`, `https`, `mailto`, and `file` schemes are
  followed; anything else is inert and shown as plain text.
- **Images** load from relative paths resolved against the document's directory, plus
  absolute paths and `file:` URLs. Remote (`http(s)`) images are **not** fetched by
  default — a placeholder is shown with a per-document "load remote images" affordance
  (privacy: opening a file should not phone home).
- **Sandbox consequence:** because Downright ships through the App Store, opening a document
  does not grant access to its *sibling* files, so relative-path images need a one-time
  per-folder grant. The first such image in a folder shows an inline "allow images from this
  folder" control; the grant is remembered. See TRD §9.
- **Typography reflow on reveal** should be minimal. Concealed markers are laid out with
  zero advance width rather than removed from the line, so revealing shifts text
  horizontally but never changes the line's vertical metrics or the caret's line.

### 7.4 Editing conveniences (v1)

- Smart list continuation: Return in a list item creates the next marker; Return on an
  empty item removes it. Tab / Shift-Tab indent and outdent list items.
- ⌘B / ⌘I / ⌘K (link) / ⌘⇧K (code) toggle markers around the selection.
- Paste: a URL pasted over a selection wraps it as `[selection](url)`. Otherwise paste is
  literal — no HTML-to-Markdown conversion in v1.
- Find and replace, with regex, scoped to the document.
- Nothing auto-formats. No format-on-save, no marker normalization.

## 8. Markdown dialect support

Downright supports a **superset** and enables features by dialect profile.

| Profile | Contents |
|---|---|
| CommonMark | The CommonMark 0.31 spec, nothing more |
| GFM (default) | CommonMark + tables, task lists, strikethrough, autolinks, footnotes |
| Extended | GFM + YAML frontmatter, highlight `==`, definition lists, math delimiters *(rendering of math is post-v1; v1 recognizes and leaves it alone)* |

**Auto-detection.** On open, Downright scans the document for dialect signals — leading
`---` frontmatter, pipe tables, `- [ ]`, `~~`, `==`, `[^ref]` — and selects the narrowest
profile that renders all of them. Detection may only *widen* from the default; it never
disables a feature the user has turned on.

**Manual override.** A per-document control (status bar + View menu) sets the profile
explicitly and pins it. The override is stored in app-level state keyed by file path —
**never written into the file**, since the file belongs to the user.

Unrecognized or ambiguous syntax is always displayed as literal source rather than
swallowed. A construct Downright cannot render must still be visible and editable.

## 9. Document and file model

- One file per window. Standard macOS document behavior: ⌘N, ⌘O, ⌘S, autosave, Versions,
  restore-on-relaunch, recent documents, window restoration.
- Reads and writes UTF-8. Detects and preserves existing line endings (LF/CRLF), final
  newline presence, and BOM. Writes are atomic.
- Detects external modification (a file changed by an LLM tool, a script, or git) and
  offers to reload; reloads silently if the document is unmodified in-app.
- Opening a path that does not exist: the CLI shim creates the empty file before handing
  it to the app (§10), so the app only ever opens files that exist. From the Open dialog
  this case cannot arise.
- No indexing of surrounding directories. No sidebar in v1 (see OQ-3).

## 10. Command line interface

```
downright [OPTIONS] [FILE...]
```

- **Fire and forget.** The command hands the paths to the app, activates it, and exits
  immediately with status 0. It never blocks waiting for the window to close, so it is
  *not* suitable as `$EDITOR`/`$GIT_EDITOR` — documented as such.
- Multiple files open multiple windows.
- Relative paths resolve against the shell's working directory.
- A nonexistent path is created as an empty file by the shim, then opened normally.
- `-n, --new` opens a new empty untitled document.
- `-v, --version`, `-h, --help`.
- Stdin (`... | downright -`) is **out of scope for v1**; see OQ-4.
- **Installation.** Downright ships through the Mac App Store and is therefore sandboxed,
  which means the app cannot install its own CLI into `/usr/local/bin`. The shim is
  distributed separately as a Homebrew formula (`brew install downright-cli`), with a
  first-run screen in the app showing the exact command for anyone not using Homebrew. The
  shim is a few lines of shell; it launches the app through Launch Services and exits.
- **A nonexistent path** is handled by the shim, not the app: the shim runs unsandboxed in
  the user's shell, so it `touch`es the file and then opens it through Launch Services like
  any other. The app receives an ordinary, existing, sandbox-granted file and autosave takes
  it from there — no save panel, no untitled-buffer special case. Accepted cost: abandoning
  `downright new.md` without typing leaves a 0-byte file behind. (Plan decision D3.)

## 11. Appearance

- Follows system light/dark appearance; a small set of built-in themes.
- User-selectable body font and monospace font, size, line height, and content column
  width (measure). Reading a long document should be comfortable by default.
- Focus/typewriter modes are post-v1 candidates, not v1.

## 12. Success criteria

**Qualitative — the bar:** the author uses Downright instead of Obsidian for opening
Markdown files within two weeks of M2, and the reveal behavior is never something they
have to think about.

**Quantitative:**

| Metric | Target |
|---|---|
| Cold launch to editable window | < 500 ms |
| `downright FILE` to window visible (app running) | < 150 ms |
| Keystroke to glyph on screen, 1 MB document | < 1 frame (8 ms @ 120 Hz) |
| Caret move / reveal repaint | < 1 frame |
| Open a 10 MB Markdown file to editable | < 1 s |
| Idle memory, one 1 MB document | < 150 MB |
| Crash-free sessions | > 99.9% |
| Data loss incidents | 0 — non-negotiable |

## 13. Release plan

| Milestone | Content |
|---|---|
| ~~**M0**~~ | ✅ **Complete** (2026-09-08) — concealment mechanism proven; see `M0-FINDINGS.md` |
| **M1** | Walking skeleton: document app, open/save/autosave, plain-text editing, CLI shim. Sandbox/Launch Services gate **passed 2026-09-08** (`R6-FINDINGS.md`). |
| **M2** | Core hybrid: headings, emphasis, inline code, links, lists, quotes, thematic breaks |
| **v0** | **First daily-use build.** M1 + M2 + fenced code blocks and clickable task checkboxes, sandboxed and dev-signed, not submitted. Scope and phases in `../03-Plan/v0-plan.md`. |
| **M3** | Blocks: fenced code with syntax highlighting, task lists, images, frontmatter |
| **M4** | Tables, footnotes, dialect profiles and auto-detection |
| **M5** | Polish: themes, preferences, find/replace, accessibility, notarized distribution |

v0 is the first daily-use build; M5 is the first shareable one.

## 14. Open questions

- **OQ-1 — Reveal granularity.** Paragraph-level reveal (specified) vs. per-span reveal.
  Paragraph-level is simpler and more predictable; per-span is visually calmer on long
  paragraphs. Recommend building paragraph-level, then evaluating per-span for inline
  spans only once M2 is in daily use.
- **OQ-2 — Table editing.** A rendered grid is much nicer to read but genuinely hard to
  edit in place. Options: (a) render a grid, reveal raw pipes on entry — the specified
  behavior; (b) never render a grid, just column-align the pipe source. Needs a prototype
  in M4 before committing.
- **OQ-3 — Sidebar.** Strictly one file per window in v1. Is a *sibling-files* sidebar
  (the documents in the same directory, no indexing) worth adding post-v1, or does that
  start the slide toward a vault?
- **OQ-4 — Stdin.** `llm ... | downright -` is an attractive fit for the LLM workflow but
  requires deciding what the buffer's identity and save target are. Deferred, not rejected.
- ~~**OQ-5 — Distribution channel.**~~ **Resolved: Mac App Store.** The sandbox
  consequences are enumerated in TRD §9 and reflected in §7.3 and §10 above. One
  dependency remains: whether Launch Services grants a sandboxed app access to a
  CLI-delivered path (TRD risk R6). That must be proven in the first week of M1 — if it
  does not hold, the App Store and the `downright FILE` workflow are mutually exclusive and
  this decision has to be revisited.
- **OQ-6 — Export.** Explicitly out of v1. Confirm that copying rendered content to the
  clipboard as rich text is also out, or whether ⌘⇧C "copy as rich text" earns a place.

# Downright

A native macOS Markdown editor with Obsidian-style hybrid editing: the document renders
as Markdown, and the line under the caret shows its raw syntax. File-first, sandboxed,
driven from the shell with `downright FILE`.

Design documents live in `designs/` (idea → PRD/TRD → plan → findings).

## Install from source

```sh
./devtool                 # build, install to /Applications, link the `downright` command
./devtool --test          # run the test suite first
./devtool --open notes.md
```

Requires Xcode; `xcodegen` is installed via Homebrew if missing. Local builds are
ad-hoc signed and sandboxed.

## Use

```sh
downright file.md            # open (creates the file if missing)
downright -p *.md            # several files open as tabs
downright -n                 # activate / new untitled document
```

Each window has a mode, switched in the status bar or with ⌘1/⌘2/⌘3: **Raw Markdown**
(monospace source), **Live Editing** (the default hybrid view), **View Only** (rendered,
read-only).

Settings are stored in `~/.config/downright.toml` and can be edited by hand or managed
with chezmoi; changes apply live.

## Develop

```sh
swift test                   # parser, editor and config tests, headless
```

`Sources/MarkdownKit` is the CommonMark/GFM parser (pure Swift), `Sources/DownrightEditor`
the TextKit 2 rendering and editing layer, `Sources/DownrightConfig` the settings file
format, and `App/` the document-based app (Xcode project generated from `project.yml`).

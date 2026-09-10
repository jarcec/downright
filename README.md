# Downright
A simple yet powerful Markdown editor with live-style editing (inspired by Obsidian) for everyday use.  No need for heavy IDE that brings markdown as side effect and yet powerful enough to be used for real work.
## Install from source
```sh
./devtool                 # build, install to /Applications, link the `downright` command
./devtool --test          # run the test suite first
```
Requires Xcode; `xcodegen` is installed via Homebrew if missing. Local builds are ad-hoc signed and sandboxed.
## Use
```sh
downright file.md            # open (creates the file if missing)
downright -p *.md            # several files open as tabs
downright -n                 # activate / new untitled document
```

Settings are stored in `~/.config/downright.toml` and can be edited by hand or managed with chezmoi; changes apply live.
## Icon

`App/Icon/render-icon.swift` draws the icon with CoreGraphics; `App/Downright/Resources/AppIcon.icns`
is its output. Regenerate with:

```sh
swift App/Icon/render-icon.swift App/Icon/Downright.iconset
iconutil -c icns App/Icon/Downright.iconset -o App/Downright/Resources/AppIcon.icns
```

## Develop
```sh
swift test                   # parser, editor and config tests, headless
```

`Sources/MarkdownKit` is the CommonMark/GFM parser (pure Swift), `Sources/DownrightEditor` the TextKit 2 rendering and editing layer, `Sources/DownrightConfig` the settings file format, and `App/` the document-based app (Xcode project generated from `project.yml`).

## License

Apache License 2.0 — see [LICENSE](LICENSE).

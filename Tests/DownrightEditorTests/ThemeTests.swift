import XCTest
import AppKit
@testable import DownrightEditor

@MainActor
final class ThemeTests: XCTestCase {
    private func render(_ theme: Theme, _ text: String, line: Int = 0) -> NSAttributedString {
        let c = EditorController(textStorage: NSTextStorage(string: text), theme: theme)
        c.layoutManager.textContainer?.size = CGSize(width: 600, height: 1e7)
        let pr = c.lines.paragraphRange(ofLine: line)
        return c.contentStorage.delegate!.textContentStorage!(c.contentStorage, textParagraphWith: pr)!.attributedString
    }

    /// Every token has a value in every built-in palette: a missing one would silently
    /// fall back to a system colour and break the theme's coherence.
    func testBuiltInPalettesAreComplete() {
        for palette in [Palette.paper, Palette.ink, Palette.system] {
            for token in ColorToken.allCases {
                XCTAssertNotEqual(palette[token].hexString, NSColor.labelColor.hexString, "\(token.rawValue)")
            }
        }
    }

    func testPaperIsLightAndInkIsDark() {
        XCTAssertFalse(Palette.paper.isDark)
        XCTAssertTrue(Palette.ink.isDark)
        func brightness(_ c: NSColor) -> CGFloat { (c.usingColorSpace(.sRGB) ?? .white).brightnessComponent }
        XCTAssertGreaterThan(brightness(Palette.ink[.text]), brightness(Palette.ink[.background]), "ink letters a dark ground")
        XCTAssertLessThan(brightness(Palette.paper[.text]), brightness(Palette.paper[.background]), "paper letters a light one")
    }

    /// Auto is one palette of dynamic colours: it resolves to Paper in aqua and Ink in
    /// dark aqua without anything being rebuilt.
    func testAutoResolvesPerAppearance() {
        for (appearance, expected) in [(NSAppearance(named: .aqua)!, Palette.paper), (NSAppearance(named: .darkAqua)!, Palette.ink)] {
            appearance.performAsCurrentDrawingAppearance {
                for token in ColorToken.allCases {
                    XCTAssertEqual(Palette.system[token].hexString, expected[token].hexString, "\(token.rawValue)")
                }
            }
        }
    }

    /// The theme reaches the page, not just the text.
    func testThemeColorsTheCanvas() {
        let c = EditorController(textStorage: NSTextStorage(string: "hello\n"), theme: Theme(palette: .ink))
        XCTAssertEqual(c.textView.backgroundColor.hexString, Palette.ink[.background].hexString)
        XCTAssertEqual(c.scrollView.backgroundColor.hexString, Palette.ink[.background].hexString)
        XCTAssertEqual(c.textView.textColor?.hexString, Palette.ink[.text].hexString)
        c.theme = Theme(palette: .paper)
        XCTAssertEqual(c.textView.backgroundColor.hexString, Palette.paper[.background].hexString)
        XCTAssertEqual(c.textView.textColor?.hexString, Palette.paper[.text].hexString)
    }

    func testDrawnTextUsesTheThemesColors() {
        let ink = render(Theme(palette: .ink), "A [link](https://example.com) here.\n")
        XCTAssertEqual((ink.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.hexString,
                       Palette.ink[.text].hexString)
        XCTAssertEqual((ink.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor)?.hexString,
                       Palette.ink[.accent].hexString, "links take the accent")
    }

    // MARK: - Custom

    func testCustomColorsApplyOverAPreset() {
        let custom = Palette.custom(["background": "#101010", "text": "#FAFAFA", "nonsense": "#FFFFFF", "marker": "not a colour"])
        XCTAssertEqual(custom[.background].hexString, "#101010FF")
        XCTAssertEqual(custom[.text].hexString, "#FAFAFAFF")
        XCTAssertEqual(custom[.marker].hexString, Palette.ink[.marker].hexString, "an unparseable value keeps the base's")
        XCTAssertEqual(custom[.accent].hexString, Palette.ink[.accent].hexString, "untouched tokens keep the base's")
        XCTAssertTrue(custom.isDark, "chrome follows the custom background")
    }

    /// The base follows the background, so naming only a dark ground does not leave the
    /// code blocks and quotes as cream boxes under pale text.
    func testCustomBaseFollowsTheBackground() {
        let dark = Palette.custom(["background": "#101418"], base: .paper)
        XCTAssertEqual(dark[.codeBlock].hexString, Palette.ink[.codeBlock].hexString)
        XCTAssertEqual(dark[.text].hexString, Palette.ink[.text].hexString)
        let light = Palette.custom(["background": "#FFFFFF"])
        XCTAssertEqual(light[.codeBlock].hexString, Palette.paper[.codeBlock].hexString)
        XCTAssertEqual(Palette.custom([:])[.text].hexString, Palette.paper[.text].hexString, "no background named: Paper")
    }

    /// What the settings file stores round-trips back to the same palette.
    func testPaletteRoundTripsThroughHexValues() {
        for palette in [Palette.paper, Palette.ink] {
            XCTAssertEqual(Palette.custom(palette.hexValues), palette)
        }
        XCTAssertEqual(Palette.paper.hexValues.count, ColorToken.allCases.count)
    }

    func testThemeEqualityTracksThePalette() {
        XCTAssertEqual(Theme(palette: .paper), Theme(palette: .paper))
        XCTAssertNotEqual(Theme(palette: .paper), Theme(palette: .ink))
        var tweaked = Theme(palette: .paper)
        tweaked.palette[.marker] = .systemPink
        XCTAssertNotEqual(tweaked, Theme(palette: .paper), "a changed colour rebuilds the decorations")
    }

    // MARK: - Slots

    /// System is one palette of dynamic colours over both slots; a fixed appearance is
    /// that slot's palette, whatever macOS is doing.
    func testAppearancePicksTheSlot() {
        var selection = ThemeSelection(appearance: .system, light: .paper, dark: .ink)
        for (appearance, expected) in [(NSAppearance(named: .aqua)!, Palette.paper), (NSAppearance(named: .darkAqua)!, Palette.ink)] {
            appearance.performAsCurrentDrawingAppearance {
                XCTAssertEqual(selection.palette[.background].hexString, expected[.background].hexString)
            }
        }
        selection.appearance = .dark
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            XCTAssertEqual(selection.palette[.background].hexString, Palette.ink[.background].hexString,
                           "a fixed appearance ignores what macOS is set to")
        }
        selection.appearance = .light
        XCTAssertEqual(selection.palette, Palette.paper)
    }

    /// Either slot can hold any theme, so Paper after dark or Ink by day both work.
    func testSlotsTakeWhicheverThemeTheyAreGiven() {
        let swapped = ThemeSelection(appearance: .system, light: .ink, dark: .paper)
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            XCTAssertEqual(swapped.palette[.background].hexString, Palette.ink[.background].hexString)
        }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            XCTAssertEqual(swapped.palette[.background].hexString, Palette.paper[.background].hexString)
        }
    }

    /// Each slot keeps its own custom colours, over its own ground.
    func testEachSlotHasItsOwnCustomColors() {
        let selection = ThemeSelection(appearance: .system, light: .custom, dark: .custom,
                                       customLight: ["accent": "#112233"], customDark: ["accent": "#445566"])
        XCTAssertEqual(selection.palette(for: .light)[.accent].hexString, "#112233FF")
        XCTAssertEqual(selection.palette(for: .dark)[.accent].hexString, "#445566FF")
        XCTAssertEqual(selection.palette(for: .light)[.codeBlock].hexString, Palette.paper[.codeBlock].hexString,
                       "the light slot fills in from Paper")
        XCTAssertEqual(selection.palette(for: .dark)[.codeBlock].hexString, Palette.ink[.codeBlock].hexString,
                       "and the dark one from Ink")
    }

    /// The app's chrome follows the page: System leaves it to macOS, a fixed appearance
    /// takes the slot's own darkness — even when the slot holds the other theme.
    func testChromeFollowsThePage() {
        XCTAssertNil(ThemeSelection(appearance: .system).chrome)
        XCTAssertEqual(ThemeSelection(appearance: .light).chrome?.name, .aqua)
        XCTAssertEqual(ThemeSelection(appearance: .dark).chrome?.name, .darkAqua)
        XCTAssertEqual(ThemeSelection(appearance: .light, light: .ink).chrome?.name, .darkAqua)
        XCTAssertEqual(ThemeSelection(appearance: .dark, dark: .custom, customDark: ["background": "#FFFFFF"]).chrome?.name, .aqua)
    }

    /// Print and the pasteboard leave the app, where a dark page would be invisible.
    func testExportIsAlwaysOnPaper() {
        var ink = Theme(palette: .ink)
        ink.bodySize = 11
        XCTAssertEqual(ink.forExport.palette, Palette.paper)
        XCTAssertEqual(ink.forExport.bodySize, 11, "only the page changes, not the type")
        let rich = RichTextExporter.attributedString(markdown: "plain text\n", theme: ink)
        XCTAssertEqual((rich.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.hexString,
                       Palette.paper[.text].hexString)
    }
}

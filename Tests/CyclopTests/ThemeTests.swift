import Foundation
import Testing
@testable import Cyclop

/// Тесты на то, как тема из `config.json` превращается в палитру.
///
/// Файл правят руками, поэтому главное здесь — что опечатка стоит одного
/// цвета, а не всей панели: неизвестное имя темы и цвет не в `#RRGGBB`
/// тихо откатываются к умолчанию.
struct ThemeTests {

    @Test func hexParsesWithAndWithoutHash() throws {
        let coral = try #require(Palette.components(hex: "#DF6B6A"))
        #expect(coral.red == 223.0 / 255)
        #expect(coral.green == 107.0 / 255)
        #expect(coral.blue == 106.0 / 255)
        #expect(Palette.components(hex: "df6b6a") != nil)
    }

    @Test func malformedHexIsRejected() {
        #expect(Palette.components(hex: "") == nil)
        #expect(Palette.components(hex: "#FFF") == nil)
        #expect(Palette.components(hex: "#GGGGGG") == nil)
        #expect(Palette.components(hex: "#FFFFFFFF") == nil)
    }

    @Test func lightnessFollowsLuminance() {
        #expect(Palette.isLight("#FFFFFF"))
        #expect(Palette.isLight("#FBF4F2"))
        #expect(Palette.isLight("#F5C286"))
        #expect(!Palette.isLight("#000000"))
        #expect(!Palette.isLight("#2A1A41"))
        #expect(!Palette.isLight("#823066"))
    }

    @Test func emptyThemeDecodesToStandard() throws {
        let choice = try JSONDecoder().decode(ThemeChoice.self, from: Data("{}".utf8))
        #expect(choice == ThemeChoice())
        #expect(Palette(choice) == .standard)
    }

    @Test func overridesSurviveRoundTrip() throws {
        var choice = ThemeChoice()
        choice.preset = "forroLight"
        choice.accent = "#0A84FF"
        let data = try JSONEncoder().encode(choice)
        #expect(try JSONDecoder().decode(ThemeChoice.self, from: data) == choice)
        // Непереопределённые цвета в файл не пишутся вовсе.
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("background"))
    }

    @Test func unknownPresetFallsBackToStandard() {
        var choice = ThemeChoice()
        choice.preset = "solarized"
        #expect(Palette(choice) == .standard)
    }

    @Test func badColourCostsOnlyThatColour() {
        var choice = ThemeChoice()
        choice.preset = "forroDark"
        choice.background = "not a colour"
        #expect(Palette(choice) == .forroDark)
    }

    /// Тёмный фон под светлой темой: её тёмный текст на нём не читался бы,
    /// поэтому текст переключается на светлый.
    @Test func backgroundOfOppositeLightnessFlipsText() {
        var choice = ThemeChoice()
        choice.preset = "forroLight"
        choice.background = "#000000"
        let palette = Palette(choice)
        #expect(palette.isDark)
        #expect(palette.text == .white)
    }

    @Test func backgroundOfSameLightnessKeepsText() {
        var choice = ThemeChoice()
        choice.preset = "forroDark"
        choice.background = "#000000"
        let palette = Palette(choice)
        #expect(palette.isDark)
        #expect(palette.text == Palette.forroDark.text)
    }
}

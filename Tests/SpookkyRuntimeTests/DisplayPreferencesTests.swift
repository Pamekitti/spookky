import XCTest
@testable import SpookkyCore

final class DisplayPreferencesTests: XCTestCase {
    func testZoomClampsAndResetKeepsTerminalAdjustment() throws {
        var value = DisplayPreferences()
        value.terminalFontAdjustment = 2
        for _ in 0..<20 { value.stepZoom(1) }
        XCTAssertEqual(value.zoom, 2)
        XCTAssertEqual(value.terminalFontSize(base: 14), 32)
        value.zoom = 1
        XCTAssertEqual(value.terminalFontSize(base: 14), 16)
        for _ in 0..<20 { value.stepZoom(-1) }
        XCTAssertEqual(value.zoom, 0.8)
        XCTAssertEqual(try JSONDecoder().decode(DisplayPreferences.self, from: JSONEncoder().encode(value)), value)
    }
    func testWindowClampDoesNotDestroyRequestedSidebarWidth() {
        var value = DisplayPreferences(); value.sidebarWidth = 600
        XCTAssertEqual(value.sidebarPoints(available: 650), 330)
        XCTAssertEqual(value.sidebarPoints(available: 1440), 600)
        XCTAssertEqual(value.sidebarWidth, 600)
        value.zoom = .nan; value.sidebarWidth = .infinity; value.terminalFontAdjustment = .nan
        value.normalize()
        XCTAssertEqual(value, DisplayPreferences())
    }
    func testAppearanceProjectionPreservesRepeatedAppearanceAndRejectsProcessOptions() {
        let appearance = GhosttyAppearance(export: """
        font-family = JetBrains Mono
        font-family = Symbols Nerd Font
        font-size = 14
        font-feature = -liga
        palette = 1=#ff0000
        palette = 2=#00ff00
        cursor-style = bar
        config-file = /tmp/included.conf
        command = unwanted-command
        initial-command = unwanted-command
        working-directory = /other
        keybind = super+c=close_surface
        env = UNWANTED=1
        window-decoration = false
        """)
        XCTAssertEqual(appearance.fontSize, 14)
        XCTAssertEqual(appearance.dependencies, ["/tmp/included.conf"])
        XCTAssertTrue(appearance.configuration.contains("font-family = Symbols Nerd Font"))
        XCTAssertTrue(appearance.configuration.contains("palette = 2=#00ff00"))
        for key in ["command", "working-directory", "keybind", "env", "window-decoration", "config-file"] {
            XCTAssertFalse(appearance.configuration.contains(key + " ="))
        }
        var display = DisplayPreferences(); display.zoom = 1.5
        XCTAssertTrue(appearance.configuration(preferences: display).contains("font-size = 21.0"))
    }
}

import AppKit
import SpookkyCore
import SpookkyRuntime

@MainActor enum DisplayPolishFixture {
    static func check(window: NSWindow, root: URL, sidebar: WorkspaceSidebarView,
                      apply: (DisplayPreferences) -> Void, tabs: () -> [WorkspaceTabView],
                      layout: (SupportingLayout) -> Void) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        var hitDetails: [String: String] = [:]
        let light = root.appendingPathComponent("appearance-light"), dark = root.appendingPathComponent("appearance-dark")
        let included = root.appendingPathComponent("appearance-include"), config = root.appendingPathComponent("appearance-config")
        try "background = #ffffff\nforeground = #111111\n".write(to: light, atomically: true, encoding: .utf8)
        try "background = #111111\nforeground = #eeeeee\n".write(to: dark, atomically: true, encoding: .utf8)
        try "font-size = 18\ncommand = never-execute-this\n".write(to: included, atomically: true, encoding: .utf8)
        let content = "theme = light:\(light.path),dark:\(dark.path)\nconfig-file = \(included.path)\nforeground = #abcdef\n"
        try content.write(to: config, atomically: true, encoding: .utf8)
        let profile = try await Task.detached { try GhosttyAppearanceFollower.readProfile(file: config.path) }.value
        checks["native_parser_resolves_both_theme_variants"] = profile.light.configuration.contains("background = #ffffff") && profile.dark.configuration.contains("background = #111111")
        checks["explicit_color_overrides_both_themes"] = profile.light.configuration.contains("foreground = #abcdef") && profile.dark.configuration.contains("foreground = #abcdef")
        checks["recursive_include_applies_without_importing_commands"] = profile.dark.fontSize == 18 && !profile.dark.configuration.contains("never-execute")
        checks["watch_dependencies_include_theme_and_include"] = Set(profile.dependencies).isSuperset(of: [light.path, dark.path, included.path])
        var observed: [GhosttyAppearanceProfile] = []
        let follower = GhosttyAppearanceFollower(file: config.path)
        follower.onAppearance = { observed.append($0) }; follower.start()
        defer { follower.stop() }
        for _ in 0..<100 { if !observed.isEmpty { break }; try await Task.sleep(for: .milliseconds(20)) }
        try "font-size = 20\n".write(to: included, atomically: true, encoding: .utf8)
        for _ in 0..<150 { if observed.last?.dark.fontSize == 20 { break }; try await Task.sleep(for: .milliseconds(20)) }
        checks["included_file_change_refreshes_appearance"] = observed.last?.dark.fontSize == 20
        var refused = false
        follower.onError = { _ in refused = true }
        try "font-size = invalid\n".write(to: included, atomically: true, encoding: .utf8)
        for _ in 0..<100 { if refused { break }; try await Task.sleep(for: .milliseconds(20)) }
        checks["invalid_appearance_preserves_last_success"] = refused && observed.last?.dark.fontSize == 20
        try "font-size = 20\n".write(to: included, atomically: true, encoding: .utf8)
        let previousCount = observed.count
        for _ in 0..<100 { if observed.count > previousCount { break }; try await Task.sleep(for: .milliseconds(20)) }
        checks["reverting_invalid_config_recovers"] = observed.count > previousCount
        let missingFolder = root.appendingPathComponent("new-config-folder"), missingConfig = missingFolder.appendingPathComponent("config")
        let directoryWatcher = AppearanceFileWatcher()
        var fileChanges = 0
        directoryWatcher.onChange = { fileChanges += 1 }
        _ = await directoryWatcher.watch([missingConfig.path])
        defer { directoryWatcher.stop() }
        try FileManager.default.createDirectory(at: missingFolder, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(500))
        checks["new_config_directory_rebind_does_not_parse"] = fileChanges == 0
        try "font-size = 17\n".write(to: missingConfig, atomically: true, encoding: .utf8)
        for _ in 0..<100 { if fileChanges > 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        checks["new_config_in_new_directory_detected"] = fileChanges == 1
        let originalFrame = window.frame
        defer { apply(DisplayPreferences()); window.setFrame(originalFrame, display: true) }
        let originalAppearance = window.appearance
        defer { window.appearance = originalAppearance }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
        for zoom in [0.8, 1.0, 1.5, 2.0] {
            for width in [650, 1440] {
                var display = DisplayPreferences(); display.zoom = zoom
                apply(display)
                window.setContentSize(NSSize(width: width, height: width == 650 ? 600 : 900))
                for mode in [SupportingLayout.split, .fullWidth] {
                    layout(mode); await Task.yield(); window.contentView?.layoutSubtreeIfNeeded()
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    await Task.yield()
                    let key = "\(appearance.rawValue)-\(Int(zoom * 100))-\(width)-\(mode.rawValue)"
                    checks["tab_height_" + key] = tabs().filter { !$0.isHiddenOrHasHiddenAncestor }.allSatisfy { abs($0.bounds.height - SpookkyStyle.headerHeight) < 1 }
                    checks["tab_children_fit_" + key] = tabs().filter { !$0.isHiddenOrHasHiddenAncestor }.allSatisfy { $0.bounds.contains($0.titleButton.frame) && $0.bounds.contains($0.closeButton.frame) }
                    if let content = window.contentView {
                        checks["sidebar_stays_in_window_" + key] = content.bounds.contains(sidebar.convert(sidebar.bounds, to: content))
                        for (index, tab) in tabs().enumerated() where !tab.isHiddenOrHasHiddenAncestor && !tab.bounds.intersection(tab.visibleRect).isEmpty {
                            for horizontal in [0.05, 0.5, 0.95] {
                            for fraction in [0.05, 0.5, 0.95] {
                                let point = tab.convert(NSPoint(x: tab.bounds.intersection(tab.visibleRect).minX + tab.bounds.intersection(tab.visibleRect).width * horizontal, y: tab.bounds.height * fraction), to: content)
                                let parentPoint = content.convert(point, to: content.superview)
                                let hit = content.hitTest(parentPoint)
                                if hit !== tab && hit?.isDescendant(of: tab) != true {
                                    hitDetails["\(key)-\(index)-\(horizontal)-\(fraction)"] = "point=\(point) rootFrame=\(content.frame) tab=\(tab.frame) visible=\(tab.visibleRect) hit=\(String(describing: hit)) key=\(window.isKeyWindow)"
                                }
                                checks["tab_hit_\(key)-\(index)-\(horizontal)-\(fraction)"] = hit === tab || hit?.isDescendant(of: tab) == true
                                tab.reconcilePointer(at: content.convert(point, to: nil))
                                checks["tab_hover_\(key)-\(index)-\(horizontal)-\(fraction)"] = !tab.closable || tab.closeButton.isRevealed
                            }
                            }
                            checks["tab_accepts_inactive_click_\(key)-\(index)"] = tab.titleButton.acceptsFirstMouse(for: nil) && tab.closeButton.acceptsFirstMouse(for: nil)
                        }
                    }
                }
                if let content = window.contentView, let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: image)
                    try image.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("display-\(appearance.rawValue)-\(Int(zoom * 100))-\(width).png"))
                }
            }
        }
        }
        apply(DisplayPreferences()); window.contentView?.layoutSubtreeIfNeeded()
        if let close = window.standardWindowButton(.closeButton), let content = window.contentView {
            let frame = close.convert(close.bounds, to: content)
            checks["traffic_lights_twenty_points_from_left"] = abs(frame.minX - 20) < 0.5
            checks["traffic_lights_centered_in_header"] = abs(content.bounds.maxY - frame.midY - 20) < 0.5
        }
        try PrivateFiles.write(hitDetails, to: root.appendingPathComponent("display-hit-details.json"))
        return checks
    }
}

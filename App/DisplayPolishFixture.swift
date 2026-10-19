import AppKit
import GhosttyKit
import SpookkyCore
import SpookkyRuntime

@MainActor enum DisplayPolishFixture {
    static func check(window: NSWindow, root: URL, sidebar: WorkspaceSidebarView,
                      activate: () async throws -> Void,
                      apply: (DisplayPreferences) -> Void, tabs: () -> [WorkspaceTabView],
                      headerActions: () -> [NSView],
                      surfaces: TerminalSurfaceManager, terminal: WorkspaceTab?, runtime: any SessionRuntime,
                      appearanceStatus: () -> String,
                      layout: (SupportingLayout) -> Void, setAppearance: (WorkspaceAppearance) -> Void) async throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        var hitDetails: [String: String] = [:]
        func inspectHeader(_ key: String) {
            guard let content = window.contentView else { return }
            content.layoutSubtreeIfNeeded()
            let actions = headerActions().filter { !$0.isHiddenOrHasHiddenAncestor }
            checks["header_actions_fit_" + key] = actions.allSatisfy {
                $0.bounds.width > 0 && content.bounds.contains($0.convert($0.bounds, to: content)) && $0.visibleRect.contains($0.bounds)
            }
            var seen = Set<ObjectIdentifier>()
            let targets: [NSView] = (tabs().map { $0 as NSView } + actions).filter {
                !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.intersection($0.visibleRect).isEmpty && seen.insert(ObjectIdentifier($0)).inserted
            }
            let frames = targets.map { $0.convert($0.bounds.intersection($0.visibleRect), to: content) }
            var disjoint = true
            for first in frames.indices {
                for second in frames.indices where second > first {
                    let overlap = frames[first].intersection(frames[second])
                    if !overlap.isNull && overlap.width > 0.5 && overlap.height > 0.5 {
                        disjoint = false
                        hitDetails["overlap-\(key)-\(first)-\(second)"] = "\(frames[first]) intersects \(frames[second])"
                    }
                }
            }
            checks["header_targets_disjoint_" + key] = disjoint
            checks["header_action_centers_receive_clicks_" + key] = actions.allSatisfy {
                let point = $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: content.superview)
                let hit = content.hitTest(point)
                return hit === $0 || hit?.isDescendant(of: $0) == true
            }
        }
        func inspectTabHits(_ key: String) {
            guard let content = window.contentView else { return }
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
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let blockedWatcher = WorkspaceFileWatcher(beforeRegistration: { entered.signal(); release.wait() })
        var staleReady = false
        blockedWatcher.onIssue = { if $0 == nil { staleReady = true } }
        blockedWatcher.watch([root.path])
        var registrationStarted = false
        for _ in 0..<100 {
            if entered.wait(timeout: .now()) == .success { registrationStarted = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        checks["blocked_watcher_registration_keeps_main_actor_responsive"] = registrationStarted && !blockedWatcher.isWatching
        blockedWatcher.stop(); release.signal()
        try await Task.sleep(for: .milliseconds(50))
        checks["cancelled_watcher_discards_stale_readiness"] = !blockedWatcher.isWatching && !staleReady

        for zoom in [0.8, 1.0, 1.5, 2.0] {
            var preferences = DisplayMetrics.preferences; preferences.zoom = zoom; apply(preferences)
            let cell = DiffCell(identifier: .init("zoom-fixture"), number: false, sign: false)
            cell.label.font = DiffCell.codeFont; cell.label.stringValue = "Åg ไทย 0123456789"
            cell.frame = NSRect(x: 0, y: 0, width: 320, height: DiffCell.lineHeight); cell.layoutSubtreeIfNeeded()
            checks["preview_text_fits_at_" + String(zoom)] = cell.label.frame.height >= cell.label.intrinsicContentSize.height &&
                cell.label.frame.minY >= 0 && cell.label.frame.maxY <= cell.bounds.height
            let notice = ProviderStartupNoticeView(focus: {}, details: {})
            notice.translatesAutoresizingMaskIntoConstraints = false
            notice.widthAnchor.constraint(equalToConstant: 320).isActive = true
            notice.update(message: "The terminal is connected, but provider startup has not been confirmed. Check its native input or trust prompts.")
            notice.frame = NSRect(x: 0, y: 0, width: 320, height: notice.fittingSize.height)
            notice.layoutSubtreeIfNeeded()
            checks["startup_notice_fits_at_" + String(zoom)] = notice.arrangedSubviews.allSatisfy { notice.bounds.contains($0.frame) }
        }
        apply(DisplayPreferences())
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
        let cacheFolder = root.appendingPathComponent("appearance-cache"), cache = cacheFolder.appendingPathComponent("profile.json")
        let follower = GhosttyAppearanceFollower(file: config.path, cache: cache)
        follower.onAppearance = { observed.append($0) }; follower.start()
        defer { follower.stop() }
        for _ in 0..<100 { if !observed.isEmpty { break }; try await Task.sleep(for: .milliseconds(20)) }
        let initialCount = observed.count
        try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
        follower.refresh()
        for _ in 0..<100 { if observed.count > initialCount && FileManager.default.fileExists(atPath: cache.path) { break }; try await Task.sleep(for: .milliseconds(20)) }
        checks["failed_cache_write_retries_on_refresh"] = FileManager.default.fileExists(atPath: cache.path)
        let cacheIdentity = try FileManager.default.attributesOfItem(atPath: cache.path)[.systemFileNumber] as? NSNumber
        let cachedCount = observed.count
        follower.refresh()
        for _ in 0..<100 { if observed.count > cachedCount { break }; try await Task.sleep(for: .milliseconds(20)) }
        let refreshedIdentity = try FileManager.default.attributesOfItem(atPath: cache.path)[.systemFileNumber] as? NSNumber
        checks["unchanged_refresh_retains_cached_file"] = observed.count > cachedCount && cacheIdentity != nil && cacheIdentity == refreshedIdentity
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
        guard let terminal, let binding = terminal.binding, let terminalView = surfaces.view(terminal.id), let initialSurface = terminalView.surface,
              let originalProcess = try await runtime.inspect(binding)?.processID else { throw LaunchError.invalid("Live appearance fixture terminal is unavailable.") }
        let initialCell = ghostty_surface_size(initialSurface).cell_height_px
        let liveConfig = root.appendingPathComponent("live-appearance-config"), liveInclude = root.appendingPathComponent("live-appearance-include")
        try "font-size = 28\n".write(to: liveInclude, atomically: true, encoding: .utf8)
        try "config-file = \(liveInclude.path)\n".write(to: liveConfig, atomically: true, encoding: .utf8)
        terminalView.insertText("SPOOKKY_APPEARANCE_DRAFT", replacementRange: NSRange(location: NSNotFound, length: 0))
        surfaces.startFollowingAppearance()
        func cellHeight() -> UInt32 { surfaces.view(terminal.id)?.surface.map { ghostty_surface_size($0).cell_height_px } ?? 0 }
        for _ in 0..<150 {
            if cellHeight() > initialCell { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["appearance_include_updates_existing_surface"] = cellHeight() > initialCell
        let acceptedCell = cellHeight()
        try "font-size = invalid\n".write(to: liveInclude, atomically: true, encoding: .utf8)
        for _ in 0..<150 {
            if appearanceStatus().localizedCaseInsensitiveContains("invalid") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["invalid_live_appearance_retains_surface_and_explains_error"] = cellHeight() == acceptedCell && appearanceStatus().localizedCaseInsensitiveContains("invalid")
        try "font-size = 32\n".write(to: liveInclude, atomically: true, encoding: .utf8)
        for _ in 0..<150 {
            if cellHeight() > acceptedCell { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["valid_live_appearance_recovers"] = cellHeight() > acceptedCell
        let refreshedProcess = try await runtime.inspect(binding)?.processID
        checks["live_appearance_preserves_surface_input_and_process"] = surfaces.view(terminal.id) === terminalView && terminalView.surface == initialSurface &&
            terminalView.visibleText().contains("SPOOKKY_APPEARANCE_DRAFT") && refreshedProcess == originalProcess
        try "".write(to: liveConfig, atomically: true, encoding: .utf8)
        for _ in 0..<150 {
            if cellHeight() == initialCell { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["appearance_fixture_restores_default_profile"] = cellHeight() == initialCell
        surfaces.stopFollowingAppearance()
        let originalFrame = window.frame
        defer { apply(DisplayPreferences()); window.setFrame(originalFrame, display: true) }
        for appearance in [WorkspaceAppearance.light, .dark] {
            setAppearance(appearance)
        for zoom in [0.8, 1.0, 1.5, 2.0] {
            for width in [650, 1440] {
                var display = DisplayPreferences(); display.zoom = zoom
                apply(display)
                let codeFont = DiffCell.codeFont
                let tabWidth = (" " as NSString).size(withAttributes: [.font: codeFont]).width * 4
                checks["diff_typography_tracks_zoom_\(appearance.rawValue)-\(Int(zoom * 100))"] =
                    abs(codeFont.pointSize - SpookkyStyle.points(12)) < 0.01 &&
                    abs(DiffCell.commentFont.pointSize - codeFont.pointSize) < 0.01 &&
                    abs(DiffCell.codeParagraph.defaultTabInterval - tabWidth) < 0.01
                window.setContentSize(NSSize(width: width, height: width == 650 ? 600 : 900))
                for mode in [SupportingLayout.split, .fullWidth] {
                    layout(mode); await Task.yield(); window.contentView?.layoutSubtreeIfNeeded()
                    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    for _ in 0..<100 {
                        if window.isKeyWindow && NSApp.isActive { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    guard window.isKeyWindow && NSApp.isActive else { throw LaunchError.invalid("Display fixture window did not activate.") }
                    checks["effective_appearance_\(appearance.rawValue)"] = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (appearance == .light ? .aqua : .darkAqua)
                    let key = "\(appearance.rawValue)-\(Int(zoom * 100))-\(width)-\(mode.rawValue)"
                    inspectHeader(key); inspectTabHits(key)
                    checks["tab_height_" + key] = tabs().filter { !$0.isHiddenOrHasHiddenAncestor }.allSatisfy { abs($0.bounds.height - SpookkyStyle.headerHeight) < 1 }
                    checks["tab_children_fit_" + key] = tabs().filter { !$0.isHiddenOrHasHiddenAncestor }.allSatisfy { $0.bounds.contains($0.titleButton.frame) && $0.bounds.contains($0.closeButton.frame) }
                    checks["selected_tab_has_readable_title_" + key] = tabs().filter { $0.selected && !$0.isHiddenOrHasHiddenAncestor }.allSatisfy {
                        let button = $0.titleButton, font = button.font ?? NSFont.systemFont(ofSize: SpookkyStyle.points(13))
                        let full = (button.title as NSString).size(withAttributes: [.font: font]).width
                        let minimum = ((String(button.title.prefix(3)) + "…") as NSString).size(withAttributes: [.font: font]).width
                        let available = button.bounds.width - 2 * button.contentInset - (button.image == nil ? 0 : SpookkyStyle.iconSlot + SpookkyStyle.iconLabelGap)
                        return available >= min(full, minimum)
                    }
                    if let content = window.contentView {
                        checks["sidebar_stays_in_window_" + key] = content.bounds.contains(sidebar.convert(sidebar.bounds, to: content))
                        if let container = sidebar.superview {
                            let frame = sidebar.convert(sidebar.bounds, to: container)
                            checks["sidebar_has_balanced_outer_margins_" + key] = abs(frame.minX - 12 * zoom) < 0.5 &&
                                abs(container.bounds.maxX - frame.maxX - 12 * zoom) < 0.5
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
        apply(DisplayPreferences())
        try await activate()
        try await transition(fullscreen: true, window: window, root: root)
        checks["native_fullscreen_enter_completed"] = true
        for zoom in [1.0, 2.0] {
            var display = DisplayPreferences(); display.zoom = zoom; apply(display)
            for mode in [SupportingLayout.split, .fullWidth] {
                layout(mode); await Task.yield()
                let key = "fullscreen-\(Int(zoom * 100))-\(mode.rawValue)"
                inspectHeader(key); inspectTabHits(key)
            }
        }
        try await activate()
        try await transition(fullscreen: false, window: window, root: root)
        checks["native_fullscreen_exit_completed"] = true
        apply(DisplayPreferences()); window.contentView?.layoutSubtreeIfNeeded()
        if let close = window.standardWindowButton(.closeButton), let content = window.contentView {
            let frame = close.convert(close.bounds, to: content)
            checks["traffic_lights_twenty_points_from_left"] = abs(frame.minX - 20) < 0.5
            checks["traffic_lights_centered_in_header"] = abs(content.bounds.maxY - frame.midY - 20) < 0.5
        }
        try PrivateFiles.write(hitDetails, to: root.appendingPathComponent("display-hit-details.json"))
        return checks
    }

    @MainActor private final class TransitionState { var completed = false }

    private static func transition(fullscreen: Bool, window: NSWindow, root: URL) async throws {
        let state = TransitionState()
        let notification = fullscreen ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
        let observer = NotificationCenter.default.addObserver(forName: notification, object: window, queue: .main) { _ in
            Task { @MainActor in state.completed = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.toggleFullScreen(nil)
        for _ in 0..<500 {
            if state.completed && window.styleMask.contains(.fullScreen) == fullscreen { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let details = ["requested_fullscreen": fullscreen, "completion_notification": state.completed,
            "native_fullscreen": window.styleMask.contains(.fullScreen), "window_visible": window.isVisible,
            "window_key": window.isKeyWindow, "app_active": NSApp.isActive]
        try PrivateFiles.write(details, to: root.appendingPathComponent("fullscreen-transition-failure.json"))
        throw LaunchError.invalid("Fullscreen regression fixture did not complete " + (fullscreen ? "entry." : "exit."))
    }
}

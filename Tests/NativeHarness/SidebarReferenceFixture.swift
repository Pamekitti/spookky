import AppKit
import Darwin
import SpookkyCore
import SpookkyRuntime

@MainActor private final class SidebarFixtureBackground: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) { SpookkyPalette.background.setFill(); bounds.fill() }
}

@MainActor enum SidebarReferenceFixture {
    static func run(window: NSWindow, root: URL, setAppearance: (WorkspaceAppearance) -> Void) async throws {
        let previousContent = window.contentView, previousFrame = window.frame, previousAppearance = window.appearance
        let content = SidebarFixtureBackground(), sidebar = WorkspaceSidebarView(frame: .zero)
        content.wantsLayer = true; window.contentView = content; content.addSubview(sidebar)
        let previous = DisplayMetrics.preferences
        defer {
            SidebarMotion.reducedOverride = nil; sidebar.closeHoverCard(); window.contentView = previousContent
            window.setFrame(previousFrame, display: true); window.appearance = previousAppearance; DisplayMetrics.preferences = previous
        }
        let repository = GitHubRepositoryID(owner: "example", name: "workspace")
        let association = ThreadPullRequest(repository: repository, number: 42, branch: "feature/sidebar", headCommit: String(repeating: "a", count: 40))
        let checkout = SidebarCheckoutInfo(repository: repository, branch: association.branch, headCommit: association.headCommit, linkedWorktree: true)
        let projectAvatar = SpookkyStyle.monogram("spookky")
        var items = [WorkspaceSidebarItem(id: "project:fixture", kind: .project, title: "spookky", image: projectAvatar)]
        let titles = ["Adopt the reference sidebar and preserve terminal input", "Improve workspace", "Find why suggested prompts disappear", "Copilot integration", "Draft interface work", "Recover interrupted activity", "Build native interface", "Session history"]
        let states: [AgentActivityState?] = [nil, .needsInput, .finished, nil, nil, .failed, .working, nil]
        for index in titles.indices {
            let provider: SessionTool = index.isMultiple(of: 2) ? .codex : .claude
            var item = WorkspaceSidebarItem(id: "reference:\(index)", kind: .conversation, title: titles[index], image: SpookkyStyle.toolImage(provider), selected: index == 0, nested: true, activity: states[index])
            item.provider = provider; item.projectName = "spookky"; item.updatedAt = Date().addingTimeInterval(-180)
            if [0, 2, 3].contains(index) { item.checkout = checkout }
            if [0, 3, 4].contains(index) { item.pullRequest = PullRequestStatus(association: association, state: index == 4 ? .draft : .merged) }
            items.append(item)
        }
        items.append(WorkspaceSidebarItem(id: "more:fixture", kind: .more, title: "Show more", nested: true))
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func cell(_ id: String) -> NSView? { descendants(sidebar).first { $0.accessibilityIdentifier() == id } }
        func snapshot(_ name: String, _ view: NSView) throws {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw LaunchError.invalid("Sidebar bitmap unavailable.") }
            view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            guard let data = bitmap.representation(using: .png, properties: [:]) else { throw LaunchError.invalid("Sidebar PNG unavailable.") }
            try data.write(to: root.appendingPathComponent(name + ".png"))
        }
        func externalCapture(_ name: String) async throws {
            guard ApplicationArguments.values.contains("--workspace-benchmark-sidebar-external-captures") else { return }
            let ready = root.appendingPathComponent("capture-ready.json"), done = root.appendingPathComponent("captured-" + name)
            try PrivateFiles.write(["variant": name], to: ready)
            defer { try? FileManager.default.removeItem(at: ready) }
            for _ in 0..<1500 {
                if FileManager.default.fileExists(atPath: done.path) { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw LaunchError.invalid("External sidebar capture timed out: " + name)
        }
        func hover(_ id: String?) {
            sidebar.pointerLocation = { _ in
                guard let id, let row = cell(id) else { return nil }
                return row.convert(NSPoint(x: 100 * DisplayMetrics.preferences.zoom, y: row.bounds.midY), to: nil)
            }
        }
        func buttons() -> [ActionButton] { descendants(sidebar).compactMap { $0 as? ActionButton }.filter { !$0.isHidden } }
        func activate() async throws {
            try await HarnessFocus.activate(window)
            for attempt in 0..<250 {
                if window.isKeyWindow && NSApp.isActive && window.occlusionState.contains(.visible) {
                    window.displayIfNeeded(); await Task.yield(); return
                }
                if attempt % 25 == 0 { NSRunningApplication.current.activate(options: [.activateAllWindows]); window.makeKeyAndOrderFront(nil) }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw LaunchError.invalid("Sidebar fixture could not activate its window: key=\(window.isKeyWindow), active=\(NSApp.isActive), visible=\(window.isVisible), occlusion=\(window.occlusionState.rawValue), frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none").")
        }
        var checks: [String: Bool] = [:]
        var diagnostics: [String: String] = [:]
        var resources: [String: Double] = [:]
        var invoked: [(String, String)] = []
        sidebar.onThreadAction = { invoked.append(($0, $1)) }
        sidebar.pointerLocation = { _ in nil }
        try await activate()
        for dark in [true, false] {
            for width in [1120, 650] {
                for zoom in [1.0, 1.5] {
                    let key = "\(dark ? "dark" : "light")-\(width)-\(Int(zoom * 100))"
                    sidebar.closeHoverCard(); hover(nil)
                    window.makeFirstResponder(nil); try await activate()
                    DisplayMetrics.preferences.zoom = zoom
                    setAppearance(dark ? .dark : .light)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.setContentSize(NSSize(width: width, height: width == 1120 ? 760 : 480))
                    sidebar.frame = NSRect(x: 0, y: 0, width: min(264 * zoom, Double(width) - 320), height: content.bounds.height)
                    content.needsDisplay = true
                    sidebar.update(items: items, collapsed: false); content.layoutSubtreeIfNeeded()
                    window.displayIfNeeded(); try await Task.sleep(for: .milliseconds(100))
                    let title = cell("reference:0")?.subviews.compactMap { $0 as? SidebarTitleField }.first
                    checks["\(key)-title-alignment"] = title.map { abs($0.frame.minX - 51 * zoom) < 0.5 } == true
                    checks["\(key)-project-title-alignment"] = cell("project:fixture")?.subviews.compactMap { $0 as? SidebarTitleField }.first.map { abs($0.frame.minX - 35 * zoom) < 0.5 } == true
                    checks["\(key)-more-alignment"] = cell("more:fixture")?.subviews.compactMap { $0 as? SidebarTitleField }.first.map { abs($0.frame.minX - 51 * zoom) < 0.5 } == true
                    checks["\(key)-row-height"] = cell("reference:0").map { abs($0.bounds.height - 31 * zoom) < 0.5 } == true
                    checks["\(key)-status-pill"] = cell("reference:1")?.subviews.compactMap { $0 as? SidebarActivityIndicator }.contains { !$0.isHidden && abs($0.bounds.height - 23 * zoom) < 0.5 } == true
                    let ringDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while cell("reference:6")?.subviews.compactMap({ $0 as? SidebarActivityIndicator }).contains(where: { !$0.isHidden && $0.rotating }) != true && ContinuousClock.now < ringDeadline {
                        try await activate(); content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    checks["\(key)-working-ring-rotates"] = cell("reference:6")?.subviews.compactMap { $0 as? SidebarActivityIndicator }.contains { !$0.isHidden && $0.rotating } == true
                    for index in [0, 1] {
                        let icon = cell("reference:\(index)")?.subviews.compactMap { $0 as? NSImageView }.first
                        checks["\(key)-provider-logo-\(index)"] = icon.map {
                            !$0.isHidden && $0.image?.accessibilityDescription == (index == 0 ? "Codex" : "Claude Code") &&
                                abs($0.frame.minX - 28 * zoom) < 0.5 && abs($0.frame.width - 16 * zoom) < 0.5
                        } == true
                    }
                    let avatar = cell("project:fixture")?.subviews.compactMap { $0 as? NSImageView }.first
                    checks["\(key)-project-avatar"] = avatar.map { !$0.isHidden && $0.image === projectAvatar && $0.contentTintColor == nil && abs($0.frame.minX - 12 * zoom) < 0.5 } == true
                    checks["\(key)-accessories-fit"] = descendants(sidebar).compactMap { $0 as? ActionButton }.allSatisfy { $0.isHidden || $0.frame.minX >= 0 && $0.frame.maxX <= ($0.superview?.bounds.width ?? 0) }
                    try await activate()
                    hover("reference:0"); content.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(650))
                    for _ in 0..<50 {
                        if sidebar.hoverCardContent != nil { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    var focusRetries = 0
                    while (!window.isKeyWindow || !NSApp.isActive), focusRetries < 3 {
                        focusRetries += 1
                        try await activate()
                        hover(nil); hover("reference:0"); content.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(700))
                    }
                    checks["\(key)-hover-actions"] = buttons().count == 2 && buttons().contains { $0.accessibilityLabel()?.hasPrefix("Pin ") == true } && buttons().contains { $0.accessibilityLabel()?.hasPrefix("Archive ") == true }
                    checks["\(key)-hover-card"] = sidebar.hoverCardContent != nil
                    checks["\(key)-hover-card-clamped"] = sidebar.hoverCardContent?.window.map { panel in
                        (window.screen?.visibleFrame.insetBy(dx: -1, dy: -1).contains(panel.frame)) == true
                    } == true
                    checks["\(key)-hover-preserves-selection"] = sidebar.selectedItemIDs == ["reference:0"]
                    checks["\(key)-hover-preserves-indent"] = title.map { abs($0.frame.minX - 51 * zoom) < 0.5 && $0.frame.width > 0 } == true
                    checks["\(key)-hover-title-clears-actions"] = title.map { title in
                        buttons().filter { $0.superview === title.superview }.allSatisfy { title.frame.maxX <= $0.frame.minX }
                    } == true
                    checks["\(key)-appearance"] = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == (dark ? .darkAqua : .aqua)
                    checks["\(key)-overflow-title-animates"] = title?.animating == true
                    diagnostics[key] = "key=\(window.isKeyWindow) active=\(NSApp.isActive) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none") hover=\(sidebar.hoveredItemID ?? "none") buttons=\(buttons().count) focusRetries=\(focusRetries) content=\(content.frame) sidebar=\(sidebar.frame) visible=\(sidebar.visibleRect) attached=\(window.contentView === content) titleOffset=\(title?.revealOffset ?? 0)"
                    if let card = sidebar.hoverCardContent { try snapshot("reference-card-" + key, card) }
                    try await externalCapture(key)
                }
            }
        }
        sidebar.closeHoverCard(); hover(nil); try await activate()
        DisplayMetrics.preferences.zoom = 1
        window.setContentSize(NSSize(width: 1120, height: 760))
        let reveal = SidebarTitleField()
        reveal.font = .systemFont(ofSize: 14); reveal.textColor = SidebarPalette.text
        reveal.stringValue = "query_timeseries tool cancellation"
        reveal.frame = NSRect(x: 450, y: 400, width: reveal.fittingSize.width - 30, height: 20)
        content.addSubview(reveal); content.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await externalCapture("title-rest")
        reveal.revealing = true; window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        checks["title-starts-without-offset"] = abs(reveal.revealOffset) < 0.5
        reveal.needsLayout = true; content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        checks["title-pauses-before-moving"] = abs(reveal.revealOffset) < 0.5
        try await Task.sleep(for: .milliseconds(450))
        checks["title-layout-does-not-restart-pause"] = reveal.revealOffset < -3
        try await Task.sleep(for: .milliseconds(1000))
        let endOffset = reveal.revealOffset
        checks["title-reaches-end"] = endOffset < -25
        try await Task.sleep(for: .milliseconds(1100))
        checks["title-holds-beyond-former-repeat"] = abs(reveal.revealOffset - endOffset) < 0.5
        try await activate()
        reveal.needsLayout = true; content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        checks["title-layout-preserves-end"] = abs(reveal.revealOffset - endOffset) < 0.5
        diagnostics["one-shot-title"] = "end=\(endOffset) held=\(reveal.revealOffset) bounds=\(reveal.bounds) active=\(reveal.animating) key=\(window.isKeyWindow) visible=\(window.occlusionState.contains(.visible)) rect=\(reveal.visibleRect)"
        try await externalCapture("title-end")
        reveal.revealing = false
        checks["title-exit-resets"] = !reveal.animating && abs(reveal.revealOffset) < 0.5
        try await activate()
        reveal.revealing = true
        try await Task.sleep(for: .milliseconds(200))
        checks["title-reentry-pauses-at-start"] = reveal.animating && abs(reveal.revealOffset) < 0.5
        try await Task.sleep(for: .milliseconds(450))
        reveal.revealing = false
        checks["title-exit-during-motion-resets"] = !reveal.animating && abs(reveal.revealOffset) < 0.5
        reveal.revealing = true
        reveal.frame.size.width += 100; reveal.updateReveal()
        checks["title-resize-to-fit-stops"] = !reveal.animating && abs(reveal.revealOffset) < 0.5
        reveal.frame.size.width -= 100; reveal.updateReveal()
        reveal.stringValue = "Short title"
        checks["title-reuse-with-fitting-text-stops"] = !reveal.animating && abs(reveal.revealOffset) < 0.5
        reveal.stringValue = String(repeating: "Very long title ", count: 10_000)
        checks["title-raster-budget-keeps-oversized-text-static"] = !reveal.animating
        reveal.stringValue = "query_timeseries tool cancellation"
        SidebarMotion.reducedOverride = true; reveal.updateReveal()
        checks["title-reduce-motion-resets-offset"] = !reveal.animating && abs(reveal.revealOffset) < 0.5
        SidebarMotion.reducedOverride = false; reveal.removeFromSuperview()
        SidebarMotion.reducedOverride = true; sidebar.displayChanged(); content.layoutSubtreeIfNeeded()
        checks["reduce-motion-stops-title"] = descendants(sidebar).compactMap { $0 as? SidebarTitleField }.allSatisfy { !$0.animating }
        checks["reduce-motion-stops-ring"] = descendants(sidebar).compactMap { $0 as? SidebarActivityIndicator }.allSatisfy { !$0.rotating }
        SidebarMotion.reducedOverride = false; sidebar.displayChanged()
        var revealRetries = 0
        while true {
            try await activate()
            hover(nil); hover("reference:0"); content.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(900))
            if window.isKeyWindow && NSApp.isActive { break }
            revealRetries += 1
            guard revealRetries <= 3 else { throw LaunchError.invalid("Sidebar title observation repeatedly lost window focus.") }
        }
        resources["titleObservationFocusRetries"] = Double(revealRetries)
        checks["title-moves-left"] = cell("reference:0")?.subviews.compactMap { $0 as? SidebarTitleField }.first.map { $0.revealOffset < -1 } == true
        diagnostics["title-movement"] = "key=\(window.isKeyWindow) active=\(NSApp.isActive) hovered=\(sidebar.hoveredItemID ?? "none") title=" + String(describing: cell("reference:0")?.subviews.compactMap { $0 as? SidebarTitleField }.first.map { "animating=\($0.animating) offset=\($0.revealOffset) bounds=\($0.bounds) visible=\($0.visibleRect)" })
        if let pin = buttons().first(where: { $0.accessibilityLabel()?.hasPrefix("Pin ") == true }) { pin.performClick(nil) }
        checks["pin-action-uses-row-identity"] = invoked.contains { $0.0 == "reference:0" && $0.1 == "pin" }
        if let archive = buttons().first(where: { $0.accessibilityLabel()?.hasPrefix("Archive ") == true }) { archive.performClick(nil) }
        checks["archive-action-uses-row-identity"] = invoked.contains { $0.0 == "reference:0" && $0.1 == "archive" }
        try await activate()
        sidebar.pointerLocation = { _ in nil }; sidebar.closeHoverCard(); sidebar.focusItem("reference:0")
        content.layoutSubtreeIfNeeded()
        await Task.yield()
        checks["keyboard-focus-reveals-actions"] = buttons().count == 2
        diagnostics["keyboard-focus"] = "key=\(window.isKeyWindow) active=\(NSApp.isActive) focused=\(sidebar.focusedItemID ?? "none") keyboard=\(sidebar.keyboardFocusItemID ?? "none") responder=\(String(describing: window.firstResponder)) buttons=\(buttons().count)"
        hover(nil); window.makeFirstResponder(content)
        var ungrouped = items[1]; ungrouped.nested = false
        let ungroupedMore = WorkspaceSidebarItem(id: "more:ungrouped", kind: .more, title: "Show more")
        sidebar.update(items: [ungrouped, ungroupedMore], collapsed: false); content.layoutSubtreeIfNeeded()
        checks["ungrouped-title-alignment"] = cell(ungrouped.id)?.subviews.compactMap { $0 as? SidebarTitleField }.first.map { abs($0.frame.minX - 35) < 0.5 } == true
        checks["ungrouped-icon-alignment"] = cell(ungrouped.id)?.subviews.compactMap { $0 as? NSImageView }.first.map { abs($0.frame.minX - 12) < 0.5 } == true
        checks["ungrouped-more-alignment"] = cell(ungroupedMore.id)?.subviews.compactMap { $0 as? SidebarTitleField }.first.map { abs($0.frame.minX - 35) < 0.5 } == true
        sidebar.update(items: items, collapsed: true); content.layoutSubtreeIfNeeded()
        checks["collapsed-nested-icon-centered"] = cell("reference:0").map { row in
            row.subviews.compactMap { $0 as? NSImageView }.first.map { abs($0.frame.midX - row.bounds.midX) < 0.5 } == true
        } == true
        let many = (0..<5000).map { WorkspaceSidebarItem(id: "recycled:\($0)", kind: .conversation, title: "Retained session \($0)") }
        sidebar.update(items: many, collapsed: false); content.layoutSubtreeIfNeeded()
        sidebar.focusItem("recycled:2500"); content.layoutSubtreeIfNeeded()
        checks["recycled-rows-bounded"] = sidebar.visibleCellCount < 60 && sidebar.visibleCellCount > 0
        resources["recycledVisibleRows"] = Double(sidebar.visibleCellCount)
        let recycledTitles = descendants(sidebar).compactMap { $0 as? SidebarTitleField }
        checks["recycled-title-does-not-retain-prior-content"] = recycledTitles.allSatisfy { !$0.stringValue.contains("Adopt the reference") } && recycledTitles.filter(\.animating).count <= 1
        sidebar.update(items: items, collapsed: false); sidebar.pointerLocation = { _ in nil }; window.makeFirstResponder(content); content.layoutSubtreeIfNeeded()
        func cpu() -> Double { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000 }
        for phase in ["idle", "hover"] {
            var seconds = 0.0, usedCPU = 0.0, excluded = 0
            for _ in 0..<40 {
                if seconds >= 5 { break }
                try await activate(); window.makeFirstResponder(content)
                hover(phase == "hover" ? "reference:0" : nil); content.layoutSubtreeIfNeeded()
                if phase == "hover" { try await Task.sleep(for: .milliseconds(550)) }
                let start = ProcessInfo.processInfo.systemUptime, before = cpu()
                try await Task.sleep(for: .milliseconds(500))
                guard window.isKeyWindow && NSApp.isActive else { excluded += 1; continue }
                seconds += ProcessInfo.processInfo.systemUptime - start; usedCPU += cpu() - before
            }
            resources[phase + "CPUPercent"] = seconds > 0 ? 100 * usedCPU / seconds : -1
            resources[phase + "Seconds"] = seconds
            resources[phase + "VisibleRows"] = Double(sidebar.visibleCellCount)
            resources[phase + "AnimatedTitles"] = Double(descendants(sidebar).compactMap { $0 as? SidebarTitleField }.filter(\.animating).count)
            resources[phase + "ActiveWindow"] = seconds >= 5 ? 1 : 0
            resources[phase + "ExcludedIntervals"] = Double(excluded)
            resources[phase + "PendingHoverTasks"] = Double(sidebar.pendingHoverTasks)
            checks[phase + "-resource-sample-active"] = seconds >= 5
            checks[phase + "-hover-tasks-bounded"] = sidebar.pendingHoverTasks <= 1
        }
        try PrivateFiles.write(checks, to: root.appendingPathComponent("sidebar-reference-checks.json"))
        try PrivateFiles.write(resources, to: root.appendingPathComponent("sidebar-reference-resources.json"))
        try PrivateFiles.write(diagnostics, to: root.appendingPathComponent("sidebar-reference-diagnostics.json"))
        guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("Sidebar reference checks failed: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", ")) }
    }
}

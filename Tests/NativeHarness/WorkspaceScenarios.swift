import AppKit
import Darwin
import SpookkyCore
import SpookkyFiles
import SpookkyRuntime
import SpookkyWorkspace
import SpookkyGit

extension WorkspaceWindowController {
    func sidebarItemIDForFixture(_ id: UUID) -> String {
        if let conversation = store.state.workspaces.first(where: { $0.id == id })?.conversationID {
            return "conversation:" + conversation.provider.rawValue + ":" + conversation.sessionID
        }
        return "workspace:" + id.uuidString
    }
    func sidebarCellForFixture(_ id: String) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == id { return view }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return find(conversationSidebar)
    }
    func checkProjectAssociation(root: URL) async throws {
        _ = try await locations.git.command(root.path, ["init", "-b", "main"]).checked()
        let location = try await locations.git.discover(root)
        var entries: [(workspace: UUID, terminal: UUID, event: AgentEvent)] = []
        for _ in 0..<2 {
            var workspaceID = UUID(), terminalID = UUID()
            store.update {
                let project = $0.registerProject(location)
                workspaceID = $0.newWorkspace(location: location, projectID: project)
                terminalID = $0.primaryTerminalID!
            }
            await launches.launch(terminalID, tool: .shell)
            guard let launch = store.state.tab(terminalID)?.launch else { throw LaunchError.invalid("Association fixture shell failed") }
            let event = AgentEvent(bindingID: launch.operationID, invocationID: UUID(), secret: UUID(), provider: .codex,
                                   kind: .finished, sessionID: UUID().uuidString.lowercased())
            store.update { _ = $0.recordAgentEvent(event) }
            entries.append((workspaceID, terminalID, event))
        }
        let first = entries[0], second = entries[1]
        store.update { $0.selectWorkspace(first.workspace) }
        var shellID = UUID()
        store.update { shellID = $0.newTab(workspaceID: first.workspace)! }
        await launches.launch(shellID, tool: .shell)
        for _ in 0..<200 {
            if surfaces.view(first.terminal) != nil && surfaces.view(shellID) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let primary = surfaces.view(first.terminal), let support = surfaces.view(shellID),
              let primaryBinding = store.state.tab(first.terminal)?.binding,
              let secondBinding = store.state.tab(second.terminal)?.binding else { throw LaunchError.invalid("Association fixture surfaces unavailable") }
        let before = try await launches.runtime.inspect(primaryBinding)
        primary.insertText("SPOOKKY_PRIMARY_ASSOCIATION_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
        support.insertText("SPOOKKY_SUPPORT_ASSOCIATION_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<100 {
            if primary.visibleText().contains("SPOOKKY_PRIMARY_ASSOCIATION_UNSENT") && support.visibleText().contains("SPOOKKY_SUPPORT_ASSOCIATION_UNSENT") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.makeFirstResponder(support)
        var checks: [String: Bool] = [:]
        func record(_ entry: (workspace: UUID, terminal: UUID, event: AgentEvent), status: ProviderProjectAssociation.Status, message: String) {
            store.update { $0.recordProjectAssociation(ProviderProjectAssociation(sessionID: entry.event.sessionID!,
                projectID: "disposable-provider-project", status: status, message: message), workspaceID: entry.workspace,
                primaryTerminalID: entry.terminal, invocationID: entry.event.invocationID, operationID: entry.event.bindingID) }
        }
        record(first, status: .unsupported, message: "Fixture: project association unsupported")
        conversationSidebar.focusItem(sidebarItemIDForFixture(first.workspace))
        window.makeFirstResponder(support)
        let sidebarID = sidebarItemIDForFixture(first.workspace)
        let row = sidebarCellForFixture(sidebarID)
        checks["primary_row_exposes_limitation"] = row?.accessibilityHelp()?.contains("Fixture: project association unsupported") == true &&
            row?.accessibilityLabel()?.isEmpty == false
        record(first, status: .associated, message: "Fixture: primary project association verified")
        record(second, status: .associated, message: "Fixture: second project association verified")
        checks["primary_row_refreshes_with_stable_identity"] = sidebarCellForFixture(sidebarID)?.accessibilityIdentifier() == sidebarID &&
            sidebarCellForFixture(sidebarID)?.accessibilityHelp()?.contains("Fixture: primary project association verified") == true
        checks["support_focus_does_not_change_owner"] = store.state.selectedTab?.id == shellID && window.firstResponder === support &&
            store.state.selected?.primaryTerminalID == first.terminal && store.state.tab(shellID)?.projectAssociation == nil
        checks["association_is_presented_on_conversation_row"] =
            (tabPairs[first.terminal]?.titleButton)?.accessibilityLabel()?.contains("Fixture: primary project association verified") != true
        checks["same_checkout_has_distinct_conversation_entries"] = entries.allSatisfy { entry in
            store.state.workspaces.first { $0.id == entry.workspace }?.primaryTerminalID == entry.terminal
        } && store.state.workspaces.first { $0.id == first.workspace }?.conversationID != store.state.workspaces.first { $0.id == second.workspace }?.conversationID
        checks["project_assignment_preserves_execution_directory"] = primaryBinding.directory == location.path && secondBinding.directory == location.path &&
            store.state.tab(first.terminal)?.launch?.directory == location.path && store.state.tab(second.terminal)?.launch?.directory == location.path
        store.update { $0.hideWorkspace(first.workspace) }
        let selection = store.state.selectedWorkspaceID
        record(first, status: .associated, message: "Fixture: hidden primary association verified")
        checks["hidden_result_retains_closed_view_and_selection"] = store.state.workspaces.first { $0.id == first.workspace }?.viewClosed == true &&
            store.state.selectedWorkspaceID == selection && store.state.workspaces.first { $0.id == first.workspace }?.currentProjectAssociation != nil
        store.update { $0.selectWorkspace(first.workspace) }
        if let renderTask { await renderTask.value }
        let after = try await launches.runtime.inspect(primaryBinding)
        checks["association_preserves_primary_process_and_input"] = before?.processID != nil && before?.processID == after?.processID &&
            surfaces.view(first.terminal)?.visibleText().contains("SPOOKKY_PRIMARY_ASSOCIATION_UNSENT") == true
        checks["association_preserves_support_input"] = surfaces.view(shellID)?.visibleText().contains("SPOOKKY_SUPPORT_ASSOCIATION_UNSENT") == true
        for (theme, size, name) in [(WorkspaceAppearance.dark, NSSize(width: 1120, height: 760), "dark-wide"), (.light, NSSize(width: 650, height: 450), "light-narrow")] {
            store.update { $0.appearance = theme }
            window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            content.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: bitmap) }
            if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: root.appendingPathComponent("project-association-" + name + ".png")) }
        }
        try await store.flush()
        checks["metadata_valid"] = (try? store.state.validate()) != nil
        try PrivateFiles.write(checks, to: root.appendingPathComponent("project-association-checks.json"))
        guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("Project association fixture failed: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", ")) }
    }
    func checkConversationIdentity(root: URL) async throws {
        let codexID = ConversationID(provider: .codex, sessionID: "00000000-0000-4000-8000-000000000011")
        let claudeID = ConversationID(provider: .claude, sessionID: "00000000-0000-4000-8000-000000000012")
        try Data("Disposable identity preview.\n".utf8).write(to: root.appendingPathComponent("identity.txt"))
        var workspaceID = UUID()
        store.update { workspaceID = $0.newWorkspace(directory: root.path) }
        let primary = store.state.primaryTerminalID!
        await launches.launch(primary, tool: .shell)
        for _ in 0..<100 {
            if surfaces.view(primary) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let surface = surfaces.view(primary), let binding = store.state.tab(primary)?.binding else {
            throw LaunchError.invalid("Identity fixture terminal did not attach.")
        }
        surface.insertText("IDENTITY_KEEP", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        let process = try await launches.runtime.inspect(binding)?.processID
        // Synthetic metadata on a disposable shell, without provider requests.
        store.update {
            $0.recordAgentEvent(AgentEvent(bindingID: binding.id, invocationID: binding.id, secret: UUID(), provider: .codex,
                                          kind: .attached, sessionID: codexID.sessionID))
            $0.setProviderTitle("Repair session continuity", conversationID: codexID)
        }
        window.makeFirstResponder(surface)
        let responder = window.firstResponder
        let pair = tabPairs[primary], sidebar = conversationSidebar
        let sidebarID = sidebarItemIDForFixture(workspaceID)
        store.update { $0.setProviderTitle("Verify session continuity", conversationID: codexID) }
        var checks: [String: Bool] = [:]
        checks["refresh_preserves_controls_and_focus"] = tabPairs[primary] === pair && conversationSidebar === sidebar && window.firstResponder === responder
        checks["refresh_preserves_sidebar_identity"] = sidebarCellForFixture(sidebarID)?.accessibilityLabel()?.contains("Verify session continuity") == true
        checks["refresh_preserves_surface_and_input"] = surfaces.view(primary) === surface && surface.visibleText().contains("IDENTITY_KEEP")
        checks["primary_tab_title_refreshes"] = (tabPairs[primary]?.titleButton)?.title == "Verify session continuity"
        checks["primary_accessibility_names_provider_and_title"] = (pair?.titleButton)?.accessibilityLabel()?.contains("Verify session continuity · Codex") == true
        checks["codex_vector_asset_available"] = SpookkyStyle.toolImage(.codex)?.isTemplate == true
        checks["claude_vector_asset_available"] = SpookkyStyle.toolImage(.claude)?.isTemplate == true
        var claudeWorkspace = UUID(), shell = UUID()
        store.update {
            claudeWorkspace = $0.ensureConversationWorkspace(claudeID, location: WorkspaceLocation(path: root.path), select: false)
            $0.setProviderTitle("Inspect saved conversations", conversationID: claudeID)
            $0.renameWorkspace(claudeWorkspace, "Claude local alias")
            $0.setProviderTitle("Claude renamed externally", conversationID: claudeID)
            shell = $0.newTab(workspaceID: workspaceID)!
        }
        await launches.launch(shell, tool: .shell)
        if let renderTask { await renderTask.value }
        guard let shellBinding = store.state.tab(shell)?.binding else { throw LaunchError.invalid("Supporting shell did not launch.") }
        let shellProcess = try await launches.runtime.inspect(shellBinding)?.processID
        surfaces.view(shell)?.insertText("SHELL_KEEP", replacementRange: NSRange(location: NSNotFound, length: 0))
        let targets: [(SupportingTarget, String)] = [(.file(path: "identity.txt"), "identity.txt"), (.browser(url: "about:blank"), "Preview"), (.terminal(tabID: shell), "Terminal")]
        for (target, title) in targets {
            store.update { $0.openSupport(target, title: title, workspaceID: workspaceID) }
            if let renderTask { await renderTask.value }
            focusSupportingContent()
            let focus = window.firstResponder, content = workspaceLayout.content.subviews.first
            let primaryControl = tabPairs[primary], sidebarControl = conversationSidebar
            store.update { $0.setProviderTitle("Title changed externally", conversationID: codexID) }
            let kind = SupportingTab(target: target, title: title).contentLabel.lowercased()
            checks["primary_identity_with_" + kind] = store.state.selected?.displayProvider == .codex && store.state.selected?.displayTitle == "Title changed externally" && store.state.primaryTerminalID == primary
            checks["refresh_preserves_" + kind + "_focus"] = window.firstResponder === focus && workspaceLayout.content.subviews.first === content && tabPairs[primary] === primaryControl && conversationSidebar === sidebarControl
        }
        checks["support_count_keeps_single_line_sidebar"] = store.state.selected?.support?.tabs.count == 3 &&
            sidebarCellForFixture(sidebarID)?.subviews.compactMap { $0 as? NSTextField }.count == 1
        checks["browser_host_installed"] = supportingContentHost != nil
        checks["same_checkout_has_distinct_conversation_rows"] = store.state.workspaces.filter { $0.directory == root.path && $0.conversationID != nil }.count == 2
        checks["local_alias_wins"] = store.state.workspaces.first { $0.id == claudeWorkspace }?.displayTitle == "Claude local alias"
        checks["support_types_keep_content_labels"] = store.state.selected?.support?.tabs.map(\.contentLabel) == ["Terminal", "File", "Browser"]
        let records = store.state.workspaces.first { $0.id == workspaceID }!.tabs
        store.update { $0.hideWorkspace(workspaceID); $0.selectWorkspace(workspaceID) }
        if let renderTask { await renderTask.value }
        let afterProcess = try await launches.runtime.inspect(binding)?.processID
        let afterShellProcess = try await launches.runtime.inspect(shellBinding)?.processID
        checks["close_reopen_keeps_processes"] = process != nil && process == afterProcess && shellProcess != nil && shellProcess == afterShellProcess
        checks["close_reopen_keeps_receipts"] = store.state.selected?.tabs == records
        checks["support_selection_keeps_primary_input"] = surfaces.view(primary)?.visibleText().contains("IDENTITY_KEEP") == true
        checks["support_selection_keeps_shell_input"] = surfaces.view(shell)?.visibleText().contains("SHELL_KEEP") == true
        if let button = tabPairs[primary]?.titleButton {
            window.makeFirstResponder(button)
            checks["primary_keyboard_focus"] = window.firstResponder === button
            guard let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124) else {
                throw LaunchError.invalid("Identity fixture keyboard event unavailable.")
            }
            button.keyDown(with: right)
            checks["primary_arrow_navigation"] = window.firstResponder === button
        }
        store.update { $0.openSupport(.file(path: "identity.txt"), title: "identity.txt"); $0.setSupportingLayout(.split, fraction: 0.55) }
        if let renderTask { await renderTask.value }
        await files.settleForFixture()
        checks["file_preview_loaded"] = (files.diagnostics["previewBytes"] ?? 0) > 0
        let firstFile = store.state.selected?.support?.selectedTabID
        try Data("Second file owns this preview.\n".utf8).write(to: root.appendingPathComponent("second.txt"))
        store.update { $0.openSupport(.file(path: "second.txt"), title: "second.txt") }
        if let renderTask { await renderTask.value }
        await files.settleForFixture()
        checks["second_file_tab_loads_its_content"] = files.previewMatchesForFixture(path: "second.txt", text: "Second file owns this preview.")
        if let firstFile { store.update { $0.selectSupport(firstFile) } }
        if let renderTask { await renderTask.value }
        await files.settleForFixture()
        checks["file_tab_switch_restores_its_content"] = files.previewMatchesForFixture(path: "identity.txt", text: "Disposable identity preview.")
        func capture(_ name: String) throws -> Bool {
            window.contentView?.layoutSubtreeIfNeeded(); window.makeFirstResponder(nil)
            guard let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return false }
            var background = NSColor.clear
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                background = window.backgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor
                content.cacheDisplay(in: content.bounds, to: bitmap)
            }
            let captured = NSImage(size: content.bounds.size); captured.addRepresentation(bitmap)
            let composite = NSImage(size: content.bounds.size, flipped: false) { bounds in
                background.setFill(); bounds.fill(); captured.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1); return true
            }
            guard let tiff = composite.tiffRepresentation, let image = NSBitmapImageRep(data: tiff),
                  let data = image.representation(using: .png, properties: [:]) else { return false }
            try data.write(to: root.appendingPathComponent(name + ".png")); return true
        }
        func toolbarGeometryIsValid() -> Bool {
            guard let heading = tabPairs[primary] else { return false }
            return threadActions.superview === heading && threadDetails.superview === heading &&
                heading.titleButton.frame.maxX <= threadActions.frame.minX + 0.5 &&
                threadActions.frame.maxX <= heading.bounds.width + 0.5 &&
                (threadDetails.isHidden || threadActions.frame.maxX < threadDetails.frame.minX && threadDetails.frame.maxX <= heading.bounds.width + 0.5) &&
                (threadChanges.isHidden || threadChanges.frame.maxX < supportingToggle.frame.minX) &&
                workspaceLayout.headerView.frame.maxX <= tabOverflow.frame.minX + 0.5 &&
                (workspaceLayout.layoutButton.isHidden || workspaceLayout.layoutButton.frame.maxX <= workspaceLayout.headerView.bounds.width + 0.5)
        }
        threadChanges.performClick(nil)
        if let renderTask { await renderTask.value }
        let changesTab = store.state.selected?.support?.selectedTabID
        checks["changes_shortcut_opens_and_focuses_changes"] = store.state.selected?.support?.selected?.target == .changes && workspaceLayout.hasFocus
        checks["changes_shortcut_has_accessible_icon"] = threadChanges.title.isEmpty && threadChanges.image != nil && threadChanges.accessibilityLabel() == "View changes"
        threadChanges.performClick(nil)
        if let renderTask { await renderTask.value }
        checks["changes_shortcut_reuses_existing_tab"] = store.state.selected?.support?.selectedTabID == changesTab && store.state.selected?.support?.tabs.filter { $0.target == .changes }.count == 1
        store.update { $0.setSupportingLayout(.collapsed) }
        threadChanges.performClick(nil)
        if let renderTask { await renderTask.value }
        checks["changes_shortcut_reveals_collapsed_panel"] = workspaceLayout.showsSupportingContent && store.state.selected?.support?.selectedTabID == changesTab
        checks["changes_shortcut_screenshot"] = try capture("identity-toolbar-changes")
        if let bitmap = threadChanges.bitmapImageRepForCachingDisplay(in: threadChanges.bounds) {
            threadChanges.cacheDisplay(in: threadChanges.bounds, to: bitmap)
            var brightness: [CGFloat] = []
            for x in 0..<bitmap.pixelsWide {
                for y in 0..<bitmap.pixelsHigh {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                        brightness.append((color.redComponent + color.greenComponent + color.blueComponent) / 3)
                    }
                }
            }
            checks["changes_shortcut_renders_visible_glyph"] = (brightness.max() ?? 0) - (brightness.min() ?? 0) > 0.1
        } else { checks["changes_shortcut_renders_visible_glyph"] = false }
        store.update { $0.selectSupport(shell); $0.setSupportingLayout(.split, fraction: 0.55) }
        if let renderTask { await renderTask.value }
        window.contentView?.layoutSubtreeIfNeeded()
        let retainedPrimary = surfaces.view(primary), retainedShell = surfaces.view(shell)
        for layout in [SupportingLayout.split, .fullWidth] {
            store.update { $0.setSupportingLayout(layout) }
            if let renderTask { await renderTask.value }
            let descriptors = store.state.selected?.support?.tabs
            supportingToggle.performClick(nil)
            if let renderTask { await renderTask.value }
            checks["panel_hide_\(layout.rawValue)"] = store.state.selected?.support?.layout == .collapsed && !body.isHidden &&
                workspaceLayout.headerView.isHidden && workspaceLayout.panel.isHidden && tabOverflow.isHidden &&
                store.state.selected?.support?.tabs == descriptors && window.firstResponder === retainedPrimary &&
                supportingToggle.accessibilityLabel() == "Show side panel"
            checks["panel_hidden_screenshot_\(layout.rawValue)"] = try capture("identity-panel-hidden-" + layout.rawValue)
            supportingToggle.performClick(nil)
            if let renderTask { await renderTask.value }
            checks["panel_restore_\(layout.rawValue)"] = store.state.selected?.support?.layout == layout &&
                store.state.selected?.support?.selectedTabID == shell && store.state.selected?.support?.fraction == 0.55 &&
                workspaceLayout.showsSupportingContent && !workspaceLayout.headerView.isHidden && workspaceLayout.hasFocus &&
                supportingToggle.accessibilityLabel() == "Hide side panel" && toolbarGeometryIsValid()
        }
        store.update { $0.setSupportingLayout(.split) }
        if let renderTask { await renderTask.value }
        checks["selected_support_has_visible_close_button"] = workspaceLayout.tabItems.first(where: { $0.selected })?.closeButton.isRevealed == true
        let supportHeaderFrame = workspaceLayout.headerView.convert(workspaceLayout.headerView.bounds, to: window.contentView)
        let primaryHeaderFrame = tabScroll.convert(tabScroll.bounds, to: window.contentView)
        let supportingFrame = workspaceLayout.panel.convert(workspaceLayout.panel.bounds, to: window.contentView)
        checks["split_tab_groups_share_one_header_row"] = abs(primaryHeaderFrame.minY - supportHeaderFrame.minY) < 1 && abs(primaryHeaderFrame.height - supportHeaderFrame.height) < 1
        checks["right_header_tracks_content_divider"] = abs(supportHeaderFrame.minX - supportingFrame.minX) < 1
        checks["support_content_has_no_stacked_tab_header"] = workspaceLayout.content.frame == workspaceLayout.panel.bounds
        checks["running_primary_has_no_duplicate_header"] = retainedPrimary?.frame.height == body.bounds.height
        checks["split_tab_screenshot"] = try capture("identity-tabs-split")
        checks["split_layout_has_full_view_icon"] = workspaceLayout.layoutButton.title.isEmpty && workspaceLayout.layoutButton.image != nil && workspaceLayout.layoutButton.accessibilityLabel() == "Full view"
        let splitPrimarySize = body.bounds.size
        workspaceLayout.layoutButton.performClick(nil)
        if let renderTask { await renderTask.value }
        checks["full_layout_has_split_view_icon"] = workspaceLayout.layoutButton.title.isEmpty && workspaceLayout.layoutButton.image != nil && workspaceLayout.layoutButton.accessibilityLabel() == "Split view"
        checks["full_support_uses_entire_content_area"] = body.isHidden && workspaceLayout.panel.frame.width == workspaceLayout.bounds.width
        checks["hidden_primary_retains_terminal_geometry"] = body.bounds.size == splitPrimarySize
        let fullSupportingSize = workspaceLayout.panel.bounds.size
        if let mainTab = tabPairs[primary]?.titleButton { mainTab.performClick(nil) }
        if let renderTask { await renderTask.value }
        window.contentView?.layoutSubtreeIfNeeded()
        checks["main_tab_selects_full_primary_without_collapsing_tabs"] = store.state.selected?.support?.layout == .fullWidth && store.state.selected?.support?.resolvedFullWidthSelection == .primary && !body.isHidden && workspaceLayout.panel.isHidden && !workspaceLayout.headerView.isHidden
        checks["full_primary_preserves_right_selection"] = store.state.selected?.support?.selectedTabID == shell
        checks["hidden_support_retains_terminal_geometry"] = workspaceLayout.panel.bounds.size == fullSupportingSize
        checks["full_headers_join_on_same_row"] = tabScroll.isHidden && workspaceLayout.joinsPrimary &&
            workspaceLayout.tabItems.first === tabPairs[primary] && workspaceLayout.tabItems.count == (store.state.selected?.support?.tabs.count ?? 0) + 1
        checks["full_primary_is_fully_visible"] = workspaceLayout.selectedTabFullyVisible
        checks["full_primary_tab_screenshot"] = try capture("identity-tabs-full-primary")
        if let browser = store.state.selected?.support?.tabs.first(where: { if case .browser = $0.target { return true }; return false }) {
            store.update { $0.selectSupport(browser.id) }
            if let renderTask { await renderTask.value }
            checks["full_browser_retains_both_terminal_surfaces"] = surfaces.view(primary) === retainedPrimary && surfaces.view(shell) === retainedShell
            checks["full_browser_tab_screenshot"] = try capture("identity-tabs-full-browser")
        }
        window.makeFirstResponder(threadActions)
        checks["primary_actions_keep_primary_focus_scope"] = window.firstResponder === threadActions && !workspaceLayout.hasFocus
        focusSupportingContent()
        workspaceLayout.layoutButton.performClick(nil)
        if let renderTask { await renderTask.value }
        checks["return_to_split_restores_saved_fraction"] = store.state.selected?.support?.fraction == 0.55 && !body.isHidden && !workspaceLayout.panel.isHidden
        store.update { $0.selectSupport(shell) }
        if let renderTask { await renderTask.value }
        for _ in 0..<100 {
            if surfaces.view(primary)?.visibleText().contains("IDENTITY_KEEP") == true && surfaces.view(shell)?.visibleText().contains("SHELL_KEEP") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["layout_switches_preserve_terminal_surfaces"] = surfaces.view(primary) === retainedPrimary && surfaces.view(shell) === retainedShell
        checks["layout_switches_preserve_primary_input"] = surfaces.view(primary)?.visibleText().contains("IDENTITY_KEEP") == true
        checks["layout_switches_preserve_supporting_input"] = surfaces.view(shell)?.visibleText().contains("SHELL_KEEP") == true
        let layoutPrimaryProcess = try await launches.runtime.inspect(binding)?.processID
        let layoutShellProcess = try await launches.runtime.inspect(shellBinding)?.processID
        checks["layout_switches_preserve_process_ids"] = layoutPrimaryProcess == process && layoutShellProcess == shellProcess
        var overflowBrowser = UUID()
        store.update { overflowBrowser = $0.openSupport(.browser(url: "about:blank"), title: "Overflow focus fixture")! }
        if let renderTask { await renderTask.value }
        window.makeFirstResponder(surfaces.view(primary))
        let overflow = tabOverflowMenu(store.state.selected!)
        guard let item = overflow.items.first(where: { $0.representedObject as? UUID == overflowBrowser }), let action = item.action else {
            throw LaunchError.invalid("Overflow browser action is unavailable.")
        }
        _ = NSApp.sendAction(action, to: item.target, from: item)
        if let renderTask { await renderTask.value }
        checks["overflow_selection_focuses_supporting_content"] = workspaceLayout.hasFocus && store.state.selected?.support?.selectedTabID == overflowBrowser
        closeSelectedTab()
        if let renderTask { await renderTask.value }
        checks["overflow_cmd_w_closes_browser_not_workspace"] = store.state.selectedWorkspaceID == workspaceID && store.state.selected?.viewClosed != true && store.state.selected?.support?.tabs.contains(where: { $0.id == overflowBrowser }) == false
        checks["overflow_close_preserves_primary_input"] = surfaces.view(primary)?.visibleText().contains("IDENTITY_KEEP") == true
        let auxiliary = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        auxiliary.isReleasedWhenClosed = false
        auxiliary.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<50 { if NSApp.keyWindow === auxiliary { break }; try await Task.sleep(for: .milliseconds(20)) }
        checks["auxiliary_window_receives_key_focus"] = NSApp.keyWindow === auxiliary
        closeSelectedTab()
        for _ in 0..<50 where auxiliary.isVisible { try await Task.sleep(for: .milliseconds(20)) }
        try PrivateFiles.write(["auxiliaryVisible": String(auxiliary.isVisible), "expectedWorkspace": workspaceID.uuidString, "actualWorkspace": store.state.selectedWorkspaceID?.uuidString ?? "nil", "viewClosed": String(store.state.selected?.viewClosed == true)], to: root.appendingPathComponent("auxiliary-close-state.json"))
        checks["close_auxiliary_window_preserves_conversation"] = !auxiliary.isVisible && store.state.selectedWorkspaceID == workspaceID && store.state.selected?.viewClosed != true
        window.makeKeyAndOrderFront(nil)
        if let firstFile { store.update { $0.selectSupport(firstFile) } }
        if let renderTask { await renderTask.value }
        await files.settleForFixture()
        var screenshots = 0
        for theme in [WorkspaceAppearance.dark, .light] {
            for width in [1120, 680] {
                store.update { $0.appearance = theme }
                window.setContentSize(NSSize(width: width, height: width == 1120 ? 760 : 480))
                if try capture("identity-revised-" + theme.rawValue + "-" + String(width)) { screenshots += 1 }
                checks["primary_header_\(theme.rawValue)_\(width)"] = tabPairs.count == 1 && tabPairs[primary]?.frame.height == SpookkyStyle.headerHeight
                checks["selected_support_tab_visible_\(theme.rawValue)_\(width)"] = workspaceLayout.selectedTabCanFit
                    ? workspaceLayout.selectedTabFullyVisible : workspaceLayout.selectedTabVisibleWidth > 0
                checks["bounded_tab_widths_\(theme.rawValue)_\(width)"] = workspaceLayout.tabItems.allSatisfy {
                    (SpookkyStyle.points(48)...$0.maximumNaturalWidth).contains($0.bounds.width)
                }
                checks["toolbar_controls_do_not_overlap_\(theme.rawValue)_\(width)"] = toolbarGeometryIsValid()
                checks["toolbar_controls_keep_utility_size_\(theme.rawValue)_\(width)"] = [threadChanges, supportingToggle, threadActions, threadDetails, workspaceLayout.layoutButton].filter { !$0.isHidden }.allSatisfy {
                    abs($0.bounds.width - SpookkyStyle.points(28)) < 1 && abs($0.bounds.height - SpookkyStyle.points(28)) < 1
                }
                checks["compact_layout_keeps_explanation_\(theme.rawValue)_\(width)"] = !workspaceLayout.compact ||
                    (!workspaceLayout.layoutButton.isEnabled && workspaceLayout.layoutButton.toolTip == "Widen the window or reduce zoom to show two readable panes")
            }
        }
        checks["desktop_narrow_both_themes"] = screenshots == 4
        let savedZoom = services.displayPreferences.zoom
        for zoom in [0.8, 1.0, 1.5, 2.0] {
            services.changeDisplay { $0.zoom = zoom }
            for width in [1120, 680] {
                window.setContentSize(NSSize(width: width, height: 760))
                if let renderTask { await renderTask.value }
                window.contentView?.layoutSubtreeIfNeeded()
                let label = "\(Int(zoom * 100))_\(width)"
                checks["toolbar_zoom_geometry_" + label] = toolbarGeometryIsValid() &&
                    (workspaceLayout.layoutButton.isHidden ||
                        abs(workspaceLayout.layoutButton.bounds.width - SpookkyStyle.points(28)) < 1 && workspaceLayout.layoutButton.frame.minX >= 0)
                checks["compact_header_keeps_changes_and_panel_actions_" + label] = !compactHeader ||
                    (threadChanges.isHidden && !supportingToggle.isHidden && headerActionsMenu(workspaceID).items.contains { $0.title == "View changes" })
                checks["toolbar_zoom_compact_state_" + label] = workspaceLayout.layoutButton.isEnabled == (!workspaceLayout.compact && store.state.selected?.support?.tabs.isEmpty == false)
            }
        }
        services.changeDisplay { $0.zoom = savedZoom }
        store.update {
            $0.recordAgentEvent(AgentEvent(bindingID: binding.id, invocationID: binding.id, secret: UUID(), provider: .codex,
                                          kind: .needsInput, sessionID: codexID.sessionID))
            $0.sidebarCollapsed = true
        }
        window.contentView?.layoutSubtreeIfNeeded()
        conversationSidebar.focusItem(sidebarID)
        let railCell = sidebarCellForFixture(sidebarID)
        checks["hidden_sidebar_has_no_duplicate_provider_rail"] = railCell == nil && conversationSidebar.itemCount == 0
        checks["hidden_sidebar_preserves_thread_provider_and_activity"] = store.state.selected?.displayProvider == .codex && store.state.selected?.activityState != nil
        for theme in [WorkspaceAppearance.dark, .light] {
            store.update { $0.appearance = theme }
            checks["rail_snapshot_" + theme.rawValue] = try capture("identity-revised-rail-" + theme.rawValue)
        }
        store.update { $0.sidebarCollapsed = false; $0.openSupport(.file(path: "identity.txt"), title: "identity.txt") }
        if let renderTask { await renderTask.value }
        focusSupportingContent()
        let oldSupport = store.state.selected?.support
        let nextID = ConversationID(provider: .codex, sessionID: "00000000-0000-4000-8000-000000000013")
        store.update {
            $0.recordAgentEvent(AgentEvent(bindingID: binding.id, invocationID: binding.id, secret: UUID(), provider: .codex,
                                          kind: .attached, sessionID: nextID.sessionID))
        }
        if let renderTask { await renderTask.value }
        checks["native_session_switch_preserves_old_row_and_support"] = store.state.workspace(for: codexID)?.id == workspaceID && store.state.workspace(for: codexID)?.support == oldSupport
        checks["background_session_switch_preserves_selection"] = store.state.selectedWorkspaceID == workspaceID
        checks["session_switch_moves_binding_once"] = store.state.workspace(for: nextID)?.primaryTerminalID == primary && store.state.workspaces.flatMap(\.tabs).filter { $0.binding?.id == binding.id }.count == 1
        if let next = store.state.workspace(for: nextID) { selectWorkspace(next.id) }
        if let renderTask { await renderTask.value }
        checks["session_switch_retains_live_process"] = try await launches.runtime.inspect(binding)?.processID == process
        checks["session_switch_retains_terminal_input"] = surfaces.view(primary)?.visibleText().contains("IDENTITY_KEEP") == true
        checks["session_switch_new_support_is_independent"] = store.state.selected?.support?.tabs.isEmpty == true
        let returningWorkspace = store.state.selectedWorkspaceID
        var draftWorkspace = UUID()
        store.update {
            draftWorkspace = $0.showLanding(homeDirectory: root.path)
            $0.editDraft($0.primaryTerminalID!, tool: .codex, prompt: "Retain this starting instruction")
        }
        let draftTerminal = store.state.primaryTerminalID!
        if let renderTask { await renderTask.value }
        supportingToggle.performClick(nil)
        if let renderTask { await renderTask.value }
        checks["empty_panel_toggle_opens_new_tab_without_agent"] = store.state.selected?.support?.selected?.target == .startPage &&
            store.state.selected?.tabs.allSatisfy { $0.binding == nil } == true && workspaceLayout.hasFocus
        let closeStartPage = workspaceLayout.tabItems.first(where: { $0.selected && $0.closable })?.closeButton
        checks["new_tab_close_is_visible"] = closeStartPage?.isRevealed == true && closeStartPage?.isHidden == false
        closeStartPage?.performClick(nil)
        if let renderTask { await renderTask.value }
        checks["last_support_close_collapses_panel"] = store.state.selected?.support?.tabs.isEmpty == true &&
            workspaceLayout.headerView.isHidden && supportingToggle.accessibilityLabel() == "Show side panel"
        guard let composer = composers[draftTerminal] else { throw LaunchError.invalid("Startup composer did not render.") }
        for (theme, width, height) in [(WorkspaceAppearance.dark, 1120, 760), (.light, 680, 480)] {
            store.update { $0.appearance = theme }
            window.setContentSize(NSSize(width: width, height: height))
            window.contentView?.layoutSubtreeIfNeeded()
            let editor = composer.convert(composer.prompt.bounds, from: composer.prompt)
            checks["startup_composer_centered_\(width)"] = abs(editor.midX - composer.bounds.midX) < 2 && editor.minX >= 24 && editor.maxX <= composer.bounds.width - 24
            checks["startup_screenshot_\(width)"] = try capture("identity-startup-" + theme.rawValue + "-" + String(width))
        }
        checks["startup_keeps_initial_draft"] = composer.prompt.string == "Retain this starting instruction"
        sessionLaunch.launch(draftTerminal)
        let cancelledLaunch = sessionLaunch.initialLaunchTasks[draftTerminal]
        if let returningWorkspace { selectWorkspace(returningWorkspace) } else { newWorkspace() }
        await cancelledLaunch?.value
        checks["leaving_new_prompt_cancels_unstarted_agent"] = store.state.tab(draftTerminal)?.binding == nil &&
            store.state.tab(draftTerminal)?.launch == nil && store.state.tab(draftTerminal)?.draft.prompt == "Retain this starting instruction"
        selectWorkspace(draftWorkspace)
        if let renderTask { await renderTask.value }
        func terminalAction(_ view: NSView) -> ActionButton? {
            if let button = view as? ActionButton, button.accessibilityLabel() == "Open Terminal and keep this session draft" { return button }
            return view.subviews.lazy.compactMap { terminalAction($0) }.first
        }
        guard let openTerminal = terminalAction(composer) else { throw LaunchError.invalid("Open Terminal control is unavailable.") }
        openTerminal.performClick(nil)
        for _ in 0..<150 {
            if store.state.selected?.tabs.contains(where: { $0.id != draftTerminal && $0.binding?.tool == .shell }) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if let renderTask { await renderTask.value }
        guard let temporaryShell = store.state.selected?.primaryTerminal, temporaryShell.id != draftTerminal,
              temporaryShell.binding?.tool == .shell, let shellWorkspace = store.state.selectedWorkspaceID else {
            throw LaunchError.invalid("Open Terminal did not start an independent shell workspace.")
        }
        checks["startup_open_terminal_preserves_agent_draft"] = store.state.tab(draftTerminal)?.draft.tool == .codex && store.state.tab(draftTerminal)?.draft.prompt == "Retain this starting instruction" && store.state.tab(draftTerminal)?.binding == nil
        checks["startup_open_terminal_has_no_agent_prompt"] = temporaryShell.launch?.tool == .shell && temporaryShell.launch?.arguments.contains("Retain this starting instruction") == false && temporaryShell.promptDelivery == .none
        checks["startup_shell_does_not_erase_provider_preference"] = store.state.lastAgentTool == .codex
        newWorkspace()
        if let renderTask { await renderTask.value }
        checks["cmd_n_restores_existing_landing_draft"] = store.state.selectedWorkspaceID == draftWorkspace &&
            composers[draftTerminal]?.prompt.string == "Retain this starting instruction" && store.state.selected?.isLanding == true
        try await launches.terminate(temporaryShell.id); surfaces.release(temporaryShell.id)
        store.update {
            $0.closeWorkspace(shellWorkspace)
            if let returningWorkspace { $0.selectWorkspace(returningWorkspace) }
        }
        if let renderTask { await renderTask.value }
        render(); window.contentView?.layoutSubtreeIfNeeded()
        checks["history_errors_do_not_use_global_footer"] = warning.isHidden
        let beforeRegistration = store.state
        var departingWorkspace = UUID()
        store.update { departingWorkspace = $0.newWorkspace(directory: root.path) }
        guard let departing = store.state.selected, let queuedTerminal = departing.primaryTerminalID else {
            throw LaunchError.invalid("Project registration fixture draft is unavailable.")
        }
        guard window.makeFirstResponder(historySearch), historySearch.currentEditor() != nil else {
            throw LaunchError.invalid("Project registration fixture search did not receive focus.")
        }
        sessionLaunch.launch(queuedTerminal, tool: .shell)
        guard let queuedLaunch = sessionLaunch.initialLaunchTasks[queuedTerminal] else {
            throw LaunchError.invalid("Project registration fixture launch was not queued.")
        }
        openDiscoveredProject(WorkspaceLocation(path: root.appendingPathComponent("registration-target").path), ifSelected: departingWorkspace)
        await queuedLaunch.value
        if let renderTask { await renderTask.value }
        checks["project_registration_completion_cancels_unstarted_launch"] = store.state.tab(queuedTerminal)?.status == .draft &&
            store.state.tab(queuedTerminal)?.launch == nil && store.state.tab(queuedTerminal)?.binding == nil
        checks["project_registration_preserves_departing_folder"] = store.state.workspaces.first { $0.id == departingWorkspace }?.selectedLocation == departing.selectedLocation
        checks["project_registration_focuses_composer"] = store.state.selected?.isLanding == true &&
            store.state.primaryTerminalID.flatMap { composers[$0]?.hasInputFocus } == true
        if store.state.tab(queuedTerminal)?.binding != nil { try await launches.terminate(queuedTerminal) }
        store.update { $0 = beforeRegistration }
        if let renderTask { await renderTask.value }
        try PrivateFiles.write(checks, to: root.appendingPathComponent("identity-checks.json"))
    }
    func checkSidebar(root: URL) async throws {
        func activate() async throws {
            try await HarnessFocus.activate(window)
            for attempt in 0..<250 {
                if NSApp.isActive && window.isKeyWindow { return }
                if attempt % 25 == 0 { NSRunningApplication.current.activate(options: [.activateAllWindows]); window.makeKeyAndOrderFront(nil) }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw LaunchError.invalid("Native fixture window did not activate.")
        }
        try await activate()
        let location = WorkspaceLocation(path: root.path)
        var projectID = UUID(), workspaceID = UUID()
        let name = "Investigate workspace navigation and preserve terminal drafts"
        store.update {
            projectID = $0.registerProject(location)
            workspaceID = $0.newWorkspace(location: location, projectID: projectID)
            $0.renameWorkspace(workspaceID, name)
            $0.editDraft($0.selectedTab!.id, tool: .codex, prompt: "Keep this unsent draft")
        }
        if let renderTask { await renderTask.value }
        try await Task.sleep(for: .milliseconds(50))
        let original = store.state.selected!
        let projectKey = "project:" + projectID.uuidString, workspaceKey = sidebarItemIDForFixture(workspaceID)
        var checks: [String: Bool] = [:]
        var interactionDetails = ["fixture_window_key": String(window.isKeyWindow), "fixture_app_active": String(NSApp.isActive)]
        try await Task.sleep(for: .milliseconds(50)); window.contentView?.layoutSubtreeIfNeeded()
        conversationSidebar.focusItem(workspaceKey)
        guard let pair = tabPairs[original.selectedTabID], let cell = sidebarCellForFixture(workspaceKey) else {
            throw LaunchError.invalid("Virtualized sidebar fixture controls are unavailable.")
        }
        if let frame = window.contentView?.superview {
            var hits: [String: String] = [:]
            for y in [2.0, 10.0, 20.0, 30.0, 38.0] {
                let point = pair.convert(NSPoint(x: pair.bounds.midX, y: y), to: frame)
                let hit = frame.hitTest(point)
                hits[String(y)] = hit.map { String(describing: type(of: $0)) } ?? "nil"
            }
            try PrivateFiles.write(hits, to: root.appendingPathComponent("header-hit-grid.json"))
        }
        let tabClose = pair.closeButton
        checks["section_accessibility_press_is_inert"] = sidebarCellForFixture("section:projects")?.accessibilityPerformPress() == false
        checks["single_line_conversation_row"] = cell.subviews.compactMap { $0 as? NSTextField }.count == 1 && abs(cell.bounds.height - 31) < 0.5
        let projectIcon = sidebarCellForFixture(projectKey)?.subviews.compactMap { $0 as? NSImageView }.first
        let conversationIcon = cell.subviews.compactMap { $0 as? NSImageView }.first
        let conversationTitle = cell.subviews.compactMap { $0 as? NSTextField }.first
        let projectTitle = sidebarCellForFixture(projectKey)?.subviews.compactMap { $0 as? NSTextField }.first
        checks["project_content_has_internal_padding"] = projectIcon.map { abs($0.convert($0.bounds, to: conversationSidebar).minX - 12) < 0.5 } == true
        checks["conversation_title_is_indented_below_project"] = conversationIcon?.isHidden == false && conversationIcon?.image != nil &&
            conversationTitle.map { abs($0.frame.minX - 51) < 0.5 } == true && projectTitle.map { abs($0.frame.minX - 35) < 0.5 } == true
        railScroll.contentView.scroll(to: NSPoint(x: 120, y: 0)); railScroll.reflectScrolledClipView(railScroll.contentView)
        checks["fixed_sidebar_controls_cannot_scroll_sideways"] = railScroll.contentView.bounds.minX == 0 && railScroll.horizontalScrollElasticity == .none
        checks["full_title_in_accessibility_without_native_tooltip"] = cell.toolTip == nil && cell.accessibilityLabel()?.contains(name) == true
        checks["thread_menu_has_archive_without_close"] = conversationSidebar.onContextMenu?(workspaceKey)?.items.contains { $0.title == "Archive" } == true && conversationSidebar.onContextMenu?(workspaceKey)?.items.contains { $0.title == "Close conversation view" } == false
        checks["compact_tab_close_target"] = abs(tabClose.frame.width - 24) < 0.5 && abs(tabClose.frame.height - 24) < 0.5
        window.makeFirstResponder(pair.titleButton); await Task.yield()
        interactionDetails["tab_close_hidden"] = String(tabClose.isHidden)
        interactionDetails["tab_close_revealed"] = String(tabClose.isRevealed)
        interactionDetails["tab_title_focused"] = String(window.firstResponder === pair.titleButton)
        checks["primary_has_no_keyboard_close_target"] = tabClose.isHidden && !pair.closable
        func key(_ code: UInt16, _ text: String = "") throws -> NSEvent {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { throw LaunchError.invalid("Sidebar keyboard event unavailable.") }
            return event
        }
        conversationSidebar.focusItem(projectKey)
        (window.firstResponder as? NSView)?.keyDown(with: try key(36, "\r"))
        checks["project_keyboard_collapses_rows"] = sidebarCellForFixture(workspaceKey) == nil && store.state.projects.first { $0.id == projectID }?.isCollapsed == true
        checks["collapse_preserves_workspace_and_draft"] = store.state.workspaces.first { $0.id == workspaceID } == original
        interactionDetails["original_workspace"] = String(data: try JSONEncoder().encode(original), encoding: .utf8)
        interactionDetails["collapsed_workspace"] = String(data: try JSONEncoder().encode(store.state.workspaces.first { $0.id == workspaceID }), encoding: .utf8)
        checks["collapse_preserves_project_keyboard_focus"] = conversationSidebar.focusedItemID == projectKey && (window.firstResponder as? NSView)?.isDescendant(of: conversationSidebar) == true
        (window.firstResponder as? NSView)?.keyDown(with: try key(36, "\r"))
        checks["expand_restores_rows"] = sidebarCellForFixture(workspaceKey) != nil
        if let scroller = conversationSidebar.subviews.first as? NSScrollView, let table = scroller.documentView as? NSTableView,
           let projectCell = sidebarCellForFixture(projectKey) {
            let point = projectCell.convert(NSPoint(x: 60, y: projectCell.bounds.midY), to: nil)
            let time = ProcessInfo.processInfo.systemUptime
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.01,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0) else { throw LaunchError.invalid("Project click fixture unavailable.") }
            NSApp.postEvent(up, atStart: true)
            table.mouseDown(with: down)
            await Task.yield()
            checks["project_mouse_click_toggles_without_selection_or_keyboard_fill"] = store.state.projects.first { $0.id == projectID }?.isCollapsed == true &&
                table.selectedRow == -1 && conversationSidebar.keyboardFocusItemID == nil && store.state.selectedWorkspaceID == workspaceID
            interactionDetails["project_click_state"] = "collapsed=\(store.state.projects.first { $0.id == projectID }?.isCollapsed == true) selectedRow=\(table.selectedRow) keyboard=\(conversationSidebar.keyboardFocusItemID ?? "none") workspace=\(store.state.selectedWorkspaceID == workspaceID)"
            conversationSidebar.focusItem(projectKey)
            (window.firstResponder as? NSView)?.keyDown(with: try key(36, "\r"))
            checks["keyboard_navigation_restores_neutral_focus_after_mouse_click"] = conversationSidebar.keyboardFocusItemID == projectKey && sidebarCellForFixture(workspaceKey) != nil
        }
        let bindings = store.state.workspaces.flatMap(\.tabs).compactMap(\.binding)
        conversationSidebar.onAddProjectSession?(projectKey)
        if let renderTask { await renderTask.value }
        checks["project_plus_opens_landing_without_agent"] = store.state.selected?.isLanding == true && store.state.selected?.projectID == projectID && store.state.workspaces.flatMap(\.tabs).compactMap(\.binding) == bindings
        store.update { $0.setProjectCollapsed(projectID, true); $0.selectWorkspace(workspaceID) }
        checks["selection_reveals_project"] = sidebarCellForFixture(workspaceKey) != nil

        if let refresh = history.historyRefreshTask { refresh.cancel(); await refresh.value }
        let originalActivate = conversationSidebar.onActivate
        var activations = 0
        var lastActivatedID: String?
        conversationSidebar.onActivate = { activations += 1; lastActivatedID = $0 }
        let virtual = (0..<5_000).map { WorkspaceSidebarItem(id: "fixture:" + String($0), kind: .conversation, title: name + " " + String($0), image: SpookkyStyle.toolImage(.codex)) }
        conversationSidebar.update(items: [virtual[0], virtual[0]], collapsed: false)
        checks["duplicate_history_ids_do_not_duplicate_rows"] = conversationSidebar.itemCount == 1
        conversationSidebar.update(items: virtual, collapsed: false)
        window.contentView?.layoutSubtreeIfNeeded(); conversationSidebar.focusItem("fixture:2500")
        checks["virtualized_views_are_bounded"] = conversationSidebar.itemCount == 5_000 && conversationSidebar.visibleCellCount > 0 && conversationSidebar.visibleCellCount < 100
        (window.firstResponder as? NSView)?.keyDown(with: try key(125))
        checks["arrow_navigation_does_not_activate"] = conversationSidebar.focusedItemID == "fixture:2501" && activations == 0
        (window.firstResponder as? NSView)?.keyDown(with: try key(36, "\r"))
        checks["return_activates_only_focused_row"] = activations == 1
        let focusedID = conversationSidebar.focusedItemID!
        let beforeY = sidebarCellForFixture(focusedID).map { $0.convert($0.bounds, to: window.contentView).minY }
        let updated = [WorkspaceSidebarItem(id: "fixture:inserted", kind: .conversation, title: "New recent conversation")] + virtual
        conversationSidebar.update(items: updated, collapsed: false); window.contentView?.layoutSubtreeIfNeeded()
        let afterY = sidebarCellForFixture(focusedID).map { $0.convert($0.bounds, to: window.contentView).minY }
        checks["refresh_preserves_scroll_anchor_and_focus"] = conversationSidebar.focusedItemID == focusedID && beforeY != nil && afterY != nil && abs(beforeY! - afterY!) < 1
        let priorActivations = activations
        checks["accessibility_press_opens_exact_row_after_refresh"] = sidebarCellForFixture(focusedID)?.accessibilityPerformPress() == true &&
            activations == priorActivations + 1 && lastActivatedID == focusedID
        if let scroller = conversationSidebar.subviews.first as? NSScrollView, let table = scroller.documentView as? NSTableView {
            let origin = scroller.contentView.bounds.origin
            for x in [CGFloat(120), -120] {
                scroller.contentView.scroll(to: NSPoint(x: x, y: origin.y))
                scroller.reflectScrolledClipView(scroller.contentView)
            }
            checks["sidebar_rejects_horizontal_scroll_and_bounce"] = scroller.contentView.bounds.minX == 0 &&
                !scroller.hasHorizontalScroller && scroller.horizontalScrollElasticity == .none
            checks["sidebar_column_matches_viewport_width"] = table.style == .plain &&
                abs(table.frame.width - scroller.contentSize.width) < 0.5 && abs(table.tableColumns[0].width - scroller.contentSize.width) < 0.5
            window.makeFirstResponder(nil)
            let local = conversationSidebar.convert(NSPoint(x: 28, y: conversationSidebar.bounds.midY), to: nil)
            let previousPointer = conversationSidebar.pointerLocation
            conversationSidebar.pointerLocation = { _ in local }
            defer { conversationSidebar.pointerLocation = previousPointer }
            await Task.yield()
            let oldHover = conversationSidebar.hoveredItemID
            scroller.contentView.scroll(to: NSPoint(x: 0, y: scroller.contentView.bounds.minY + 96))
            scroller.reflectScrolledClipView(scroller.contentView)
            try await Task.sleep(for: .milliseconds(40))
            let row = table.row(at: table.convert(local, from: nil))
            let expected = updated.indices.contains(row) ? updated[row].id : nil
            interactionDetails["hover_before_scroll"] = oldHover ?? "none"
            interactionDetails["hover_after_scroll"] = conversationSidebar.hoveredItemID ?? "none"
            interactionDetails["expected_hover_after_scroll"] = expected ?? "none"
            checks["scroll_reconciles_stationary_pointer"] = oldHover != nil && expected != nil && oldHover != expected && conversationSidebar.hoveredItemID == expected
            func actions(_ view: NSView) -> [ActionButton] { (view as? ActionButton).map { [$0] } ?? view.subviews.flatMap { actions($0) } }
            checks["two_direct_hover_actions_visible"] = actions(conversationSidebar).filter { !$0.isHidden }.count == 2
            interactionDetails["visible_hover_accessories"] = String(actions(conversationSidebar).filter { !$0.isHidden }.count)
            let title = expected.flatMap { sidebarCellForFixture($0) }?.subviews.compactMap { $0 as? NSTextField }.first
            checks["hover_title_stays_single_line_and_clipped"] = title?.maximumNumberOfLines == 1 && title?.layer?.animationKeys()?.isEmpty != false
            window.orderOut(nil); await Task.yield()
            checks["inactive_window_hides_all_row_accessories"] = actions(conversationSidebar).allSatisfy(\.isHidden)
            try await activate()
            checks["reactivation_reveals_only_hovered_row_accessory"] = window.isKeyWindow && actions(conversationSidebar).filter { !$0.isHidden }.count == 2
            scroller.contentView.scroll(to: NSPoint(x: 0, y: scroller.contentView.bounds.minY + 96))
            scroller.reflectScrolledClipView(scroller.contentView); await Task.yield()
            let reactivatedRow = table.row(at: table.convert(local, from: nil))
            checks["reactivated_scroll_hides_other_row_accessories"] = updated.indices.contains(reactivatedRow) &&
                conversationSidebar.hoveredItemID == updated[reactivatedRow].id && actions(conversationSidebar).filter { !$0.isHidden }.count == 2
            conversationSidebar.pointerLocation = { _ in nil }
            conversationSidebar.focusItem(focusedID); await Task.yield()
            let accessory = sidebarCellForFixture(focusedID)?.subviews.compactMap { $0 as? ActionButton }.first
            checks["keyboard_focus_reveals_only_its_row_accessory"] = accessory?.isHidden == false && actions(conversationSidebar).filter { !$0.isHidden }.count == 2
            if let accessory { window.makeFirstResponder(accessory) }
            await Task.yield()
            checks["revealed_row_accessory_accepts_keyboard_focus"] = accessory != nil && window.firstResponder === accessory && accessory?.isHidden == false
        }
        guard let menuAnchor = sidebarCellForFixture(focusedID) else { throw LaunchError.invalid("Menu refresh fixture anchor is unavailable.") }
        let refreshMenu = NSMenu(); refreshMenu.addItem(ClosureMenuItem("Retained history action") {})
        var menuOpened = false, menuEnded = false, refreshedDuringMenu = false
        let began = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: refreshMenu, queue: .main) { _ in
            MainActor.assumeIsolated { menuOpened = true }
        }
        let ended = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: refreshMenu, queue: .main) { _ in
            MainActor.assumeIsolated { menuEnded = true }
        }
        let cancelMenu: @MainActor @Sendable () -> Void = { refreshMenu.cancelTracking() }
        let menuRefresh = Timer(timeInterval: 0.2, repeats: false) { [self] _ in
            MainActor.assumeIsolated {
                conversationSidebar.update(items: Array(updated.prefix(20)), collapsed: false)
                conversationSidebar.update(items: Array(updated.prefix(25)), collapsed: false)
                refreshedDuringMenu = true
                checks["history_refresh_retains_open_menu_anchor"] = conversationSidebar.itemCount == updated.count && sidebarCellForFixture(focusedID) === menuAnchor
                checks["history_refresh_keeps_native_menu_tracking"] = menuOpened && !menuEnded
                cancelMenu()
            }
        }
        RunLoop.main.add(menuRefresh, forMode: .common)
        refreshMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: menuAnchor.bounds.maxY), in: menuAnchor)
        menuRefresh.invalidate(); NotificationCenter.default.removeObserver(began); NotificationCenter.default.removeObserver(ended)
        await Task.yield()
        try await activate()
        checks["native_menu_refresh_fixture_exercised"] = menuOpened && refreshedDuringMenu
        checks["menu_close_applies_latest_history_snapshot"] = conversationSidebar.itemCount == 25
        checks["history_navigation_starts_no_agents"] = store.state.workspaces.flatMap(\.tabs).compactMap(\.binding) == bindings
        conversationSidebar.onActivate = originalActivate
        renderChrome(); conversationSidebar.focusItem(workspaceKey)
        var screenshots = 0
        for (theme, size) in [(WorkspaceAppearance.dark, NSSize(width: 1120, height: 760)), (.light, NSSize(width: 650, height: 450))] {
            store.update { $0.appearance = theme }; window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded(); window.makeFirstResponder(nil)
            guard let content = window.contentView, let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { continue }
            window.effectiveAppearance.performAsCurrentDrawingAppearance { content.cacheDisplay(in: content.bounds, to: image) }
            if let png = image.representation(using: .png, properties: [:]) { try png.write(to: root.appendingPathComponent("sidebar-" + theme.rawValue + ".png")); screenshots += 1 }
        }
        checks["wide_and_narrow_native_snapshots"] = screenshots == 2
        store.update { $0.appearance = .dark }; window.setContentSize(NSSize(width: 1120, height: 760))
        var shellID: UUID?
        store.update { shellID = $0.newTab() }
        guard let shellID else { throw LaunchError.invalid("Sidebar shell fixture is unavailable.") }
        await launches.launch(shellID, tool: .shell)
        for _ in 0..<100 { if surfaces.view(shellID) != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        guard let surface = surfaces.view(shellID), let binding = store.state.tab(shellID)?.binding else { throw LaunchError.invalid("Sidebar shell fixture did not attach.") }
        if let task = renderTask { await task.value }
        let shellReadyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while surface.visibleText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ContinuousClock.now < shellReadyDeadline { try await Task.sleep(for: .milliseconds(20)) }
        guard !surface.visibleText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LaunchError.invalid("Sidebar shell did not produce its prompt.") }
        for green in [false, true] {
            try await activate()
            let rgb = green ? "0;255;0" : "255;0;0"
            let command = "if [[ -z ${NO_COLOR-} && $COLORTERM == truecolor ]]; then printf '\\033[2J\\033[H\\033[48;2;" + rgb + "m                \\033[0m\\nSPOOKKY_NATIVE_COLOR_ENV_OK\\n'; fi"
            surface.insertText(command, replacementRange: NSRange(location: NSNotFound, length: 0))
            surface.keyDown(with: try key(36, "\r"))
            for _ in 0..<150 {
                if RenderedFixtureProbe.matches(surface, green: green) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            checks[green ? "native_truecolor_green_survives_tmux" : "native_truecolor_red_survives_tmux"] =
                surface.visibleText().contains("SPOOKKY_NATIVE_COLOR_ENV_OK") && RenderedFixtureProbe.matches(surface, green: green)
        }
        surface.insertText("for i in {1..120}; do printf 'READ_CHECK_%s\\n' \"$i\"; done", replacementRange: NSRange(location: NSNotFound, length: 0))
        surface.keyDown(with: try key(36, "\r"))
        try await Task.sleep(for: .milliseconds(250))
        try await surfaces.scrollFixtureHistory(shellID, offset: 25)
        let invocation = UUID(), secret = UUID()
        func activityEvent(_ kind: AgentEventKind) -> AgentEvent {
            AgentEvent(bindingID: binding.id, invocationID: invocation, secret: secret, provider: .codex, kind: kind)
        }
        store.update { $0.recordAgentEvent(activityEvent(.working)); $0.recordAgentEvent(activityEvent(.finished)) }
        try await Task.sleep(for: .milliseconds(250))
        let scrolledBottom = try await surfaces.viewportAtBottom(shellID)
        checks["completion_stays_unread_in_real_scrollback"] = store.state.tab(shellID)?.activity?.unread == true && scrolledBottom == false
        interactionDetails["observed_scrolled_bottom"] = String(describing: scrolledBottom)
        try await surfaces.scrollFixtureHistory(shellID, offset: 0)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(surface); NSApp.activate(ignoringOtherApps: true)
        refreshAgentAttention()
        for _ in 0..<100 {
            if store.state.tab(shellID)?.activity?.unread == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["completion_acknowledged_at_real_terminal_bottom"] = store.state.tab(shellID)?.activity?.unread == false
        interactionDetails["observed_live_bottom"] = String(describing: try await surfaces.viewportAtBottom(shellID))
        if let ownerID = store.state.workspace(containing: shellID)?.id {
            store.update { _ = $0.showLanding(homeDirectory: root.path) }
            if let renderTask { await renderTask.value }
            store.update { $0.recordAgentEvent(activityEvent(.working)); $0.recordAgentEvent(activityEvent(.finished)) }
            try await Task.sleep(for: .milliseconds(200))
            checks["background_completion_remains_unread"] = store.state.tab(shellID)?.activity?.unread == true
            store.update { $0.selectWorkspace(ownerID); $0.selectTab(shellID); $0.setSupportingLayout(.split) }
            if let renderTask { await renderTask.value }
            refreshAgentAttention()
            for _ in 0..<100 {
                if store.state.tab(shellID)?.activity?.unread == false { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            checks["visible_split_terminal_acknowledges_completion"] = store.state.tab(shellID)?.activity?.unread == false
        }
        guard let cancelCopyMode = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{3}", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) else { throw LaunchError.invalid("Copy-mode cancellation event unavailable.") }
        surface.keyDown(with: cancelCopyMode)
        for _ in 0..<100 {
            if try await surfaces.observedViewport(shellID) == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["return_to_bottom_keeps_live_terminal_input"] = try await surfaces.observedViewport(shellID) == nil
        store.update { $0.recordAgentEvent(activityEvent(.needsInput)) }
        refreshAgentAttention(); try await Task.sleep(for: .milliseconds(100))
        checks["viewing_real_terminal_keeps_input_request"] = store.state.tab(shellID)?.activity?.displayState == .needsInput
        store.update { $0.recordAgentEvent(activityEvent(.failed)) }
        refreshAgentAttention(); try await Task.sleep(for: .milliseconds(100))
        checks["viewing_real_terminal_keeps_failure"] = store.state.tab(shellID)?.activity?.displayState == .failed
        guard let viewportOwner = launches.runtime as? WorkspaceViewportFixtureRuntime else {
            throw LaunchError.invalid("Sidebar viewport race fixture is unavailable.")
        }
        store.update { $0.resetAgent(shellID) }
        for task in Array(acknowledgmentTasks.values) { await task.value }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(surface); NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<100 {
            if agentTargetVisible(shellID), try await surfaces.viewportAtBottom(shellID) == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        interactionDetails["acknowledgment_race_setup"] = "visible=\(agentTargetVisible(shellID)) revision=\(surface.viewportRevision) bottom=\(String(describing: try await surfaces.viewportAtBottom(shellID))) pending=\(acknowledgmentTasks[shellID] != nil)"
        try PrivateFiles.write(interactionDetails, to: root.appendingPathComponent("sidebar-interaction-diagnostics.json"))
        await viewportOwner.holdViewport(after: 1)
        store.update { $0.recordAgentEvent(activityEvent(.working)); $0.recordAgentEvent(activityEvent(.finished)) }
        refreshAgentAttention()
        for _ in 0..<100 {
            if await viewportOwner.isHeld { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await viewportOwner.isHeld else { throw LaunchError.invalid("Sidebar acknowledgment did not reach its delayed bottom query.") }
        let bottomAcknowledgment = acknowledgmentTasks[shellID]
        surface.onViewportInteraction?()
        checks["pending_scroll_keeps_viewport_unknown"] = try await surfaces.viewportAtBottom(shellID) == nil
        try await surfaces.scrollFixtureHistory(shellID, offset: 25)
        try await Task.sleep(for: .milliseconds(150))
        await viewportOwner.resume()
        await bottomAcknowledgment?.value
        for task in Array(acknowledgmentTasks.values) { await task.value }
        checks["scroll_during_bottom_query_retains_unread"] = store.state.tab(shellID)?.activity?.unread == true
        await viewportOwner.holdViewport(after: 1)
        refreshAgentAttention()
        for _ in 0..<100 {
            if await viewportOwner.isHeld { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await viewportOwner.isHeld else { throw LaunchError.invalid("Sidebar acknowledgment did not reach its delayed scrollback query.") }
        let scrollbackAcknowledgment = acknowledgmentTasks[shellID]
        surface.onViewportInteraction?()
        try await surfaces.scrollFixtureHistory(shellID, offset: 0)
        try await Task.sleep(for: .milliseconds(150))
        await viewportOwner.resume()
        await scrollbackAcknowledgment?.value
        for _ in 0..<100 {
            if store.state.tab(shellID)?.activity?.unread == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["return_to_bottom_during_query_retries_acknowledgment"] = store.state.tab(shellID)?.activity?.unread == false
        interactionDetails["acknowledgment_race_result"] = "visible=\(agentTargetVisible(shellID)) revision=\(surface.viewportRevision) bottom=\(String(describing: try await surfaces.viewportAtBottom(shellID))) pending=\(acknowledgmentTasks[shellID] != nil)"
        try PrivateFiles.write(interactionDetails, to: root.appendingPathComponent("sidebar-interaction-diagnostics.json"))
        surface.keyDown(with: cancelCopyMode)
        for _ in 0..<100 {
            if try await surfaces.observedViewport(shellID) == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        store.update { $0.resetAgent(shellID) }
        surface.insertText("SPOOKKY_SIDEBAR_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
        func unsentInputVisible() -> Bool { surface.visibleText().replacingOccurrences(of: "\n", with: "").contains("SPOOKKY_SIDEBAR_UNSENT") }
        for _ in 0..<100 {
            if unsentInputVisible() { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        interactionDetails["input_before_collapse"] = String(surface.visibleText().suffix(300))
        let before = try await launches.runtime.inspect(binding)
        conversationSidebar.onActivate?(projectKey)
        let after = try await launches.runtime.inspect(binding)
        checks["collapse_preserves_running_process"] = before?.processID != nil && before?.processID == after?.processID && surfaces.view(shellID) === surface
        conversationSidebar.onActivate?(projectKey)
        checks["collapse_preserves_terminal_input"] = unsentInputVisible()
        interactionDetails["input_after_collapse"] = String(surface.visibleText().suffix(300))
        checks["agent_draft_survives_shell_and_collapse"] = store.state.tab(original.selectedTabID)?.draft == original.tabs[0].draft
        checks.merge(try await checkActivityRecovery(root: root, terminal: shellID), uniquingKeysWith: { _, new in new })
        try await activate()
        chooseSupportingFile()
        guard let picker = filePicker, let pickerWindow = picker.view.window,
              let pickerResponder = pickerWindow.firstResponder else { throw LaunchError.invalid("Focus fixture file picker did not open.") }
        checks["focus_fixture_file_picker_is_key"] = picker.popover.isShown && pickerWindow.isKeyWindow
        contentKey = ""; render()
        if let renderTask { await renderTask.value }
        checks["terminal_reattach_preserves_file_picker_focus"] = picker.popover.isShown && pickerWindow.isKeyWindow && pickerWindow.firstResponder === pickerResponder
        picker.popover.performClose(nil)
        try await activate()
        window.makeFirstResponder(historySearch)
        guard let searchResponder = historySearch.currentEditor() else { throw LaunchError.invalid("Focus fixture sidebar search did not begin editing.") }
        contentKey = ""; render()
        if let renderTask { await renderTask.value }
        checks["terminal_reattach_preserves_sidebar_search_focus"] = window.firstResponder === searchResponder && historySearch.currentEditor() === searchResponder
        window.makeFirstResponder(surface)
        contentKey = ""; render()
        window.makeFirstResponder(historySearch)
        guard let laterResponder = historySearch.currentEditor() else { throw LaunchError.invalid("Late focus fixture sidebar search did not begin editing.") }
        if let renderTask { await renderTask.value }
        checks["late_terminal_attachment_preserves_new_search_focus"] = window.firstResponder === laterResponder && historySearch.currentEditor() === laterResponder
        window.makeFirstResponder(surface)
        func nativeControls(_ view: NSView) -> [NSControl] { (view as? NSControl).map { [$0] } ?? view.subviews.flatMap(nativeControls) }
        let controls = nativeControls(window.contentView!).filter { control in
            if let field = control as? NSTextField { return field.isEditable || field.isSelectable }
            return control is NSButton || control is NSTableView
        }
        checks["native_chrome_controls_have_no_focus_ring"] = !controls.isEmpty && controls.allSatisfy { $0.focusRingType == .none && $0.cell?.focusRingType != .exterior }
        let nativeAlert = ChromeAlert()
        let standardControls: [NSControl] = [ChromeTextField(), ChromeSearchField(), ChromePopUpButton(), ChromeButton(), nativeAlert.addButton(withTitle: "Done")]
        checks["shared_native_control_defaults_suppress_focus_rings"] = standardControls.allSatisfy { $0.focusRingType == .none && $0.cell?.focusRingType == NSFocusRingType.none }
        checks["custom_search_cells_remain_editable"] = historySearch.isEditable && historySearch.isSelectable &&
            standardControls.compactMap { $0 as? NSSearchField }.allSatisfy { $0.isEditable && $0.isSelectable }
        interactionDetails["native_control_focus_types"] = controls.map { String(describing: type(of: $0)) + ":" + String($0.focusRingType.rawValue) + ":" + String(describing: $0.cell?.focusRingType) }.joined(separator: ", ")
        let action = ActionButton("Keyboard action", action: {})
        let intrinsicSize = action.intrinsicContentSize
        let buttonFrame = NSRect(x: 24, y: 24, width: 140, height: 28)
        action.frame = buttonFrame; window.contentView?.addSubview(action)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<100 {
            if window.isKeyWindow && NSApp.isActive { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.makeFirstResponder(action)
        checks["keyboard_button_feedback_keeps_bounds_and_intrinsic_size"] = action.showsKeyboardFocus && action.frame == buttonFrame && action.intrinsicContentSize == intrinsicSize && action.focusRingType == .none
        action.removeFromSuperview(); window.makeFirstResponder(surface)
        NSApp.sendAction(NSSelectorFromString("showSettings"), to: services, from: nil)
        if let settings = NSApp.windows.first(where: { $0.title == "Spookky Settings" }), let content = settings.contentView {
            let settingsControls = nativeControls(content).filter { control in
                if let field = control as? NSTextField { return field.isEditable || field.isSelectable }
                return control is NSButton || control is NSSlider
            }
            checks["settings_controls_have_no_focus_ring"] = settingsControls.contains { $0 is NSSlider } && settingsControls.allSatisfy {
                $0.focusRingType == .none && $0.cell?.focusRingType == NSFocusRingType.none
            }
            settings.close(); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(surface)
        } else { checks["settings_controls_have_no_focus_ring"] = false }
        func cpuSeconds() -> Double {
            var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let idleStart = cpuSeconds(), idleTime = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(2))
        let idleCPU = (cpuSeconds() - idleStart) / (ProcessInfo.processInfo.systemUptime - idleTime) * 100
        conversationSidebar.focusItem(workspaceKey)
        let activeStart = cpuSeconds(), activeTime = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(2))
        let activeCPU = (cpuSeconds() - activeStart) / (ProcessInfo.processInfo.systemUptime - activeTime) * 100
        window.makeFirstResponder(nil)
        let resources: [String: Double] = ["idle_app_cpu_percent": idleCPU, "focused_sidebar_app_cpu_percent": activeCPU,
            "app_rss_mib": WorkspaceDiagnostics.residentMiB() ?? -1, "terminal_session_count": 1,
            "virtual_history_items": 5_000, "mounted_sidebar_cells": Double(conversationSidebar.visibleCellCount)]
        if ApplicationArguments.values.contains("--workspace-benchmark-display") {
            try PrivateFiles.write(checks, to: root.appendingPathComponent("sidebar-checks.json"))
            store.update { $0.openSupport(.changes, title: "Changes"); $0.openSupport(.file(path: root.appendingPathComponent("appearance-config").path), title: "Settings file") }
            checks.merge(try await DisplayPolishFixture.check(window: window, root: root, sidebar: conversationSidebar,
                activate: activate, synchronize: { if let task = self.renderTask { await task.value }; self.window.contentView?.layoutSubtreeIfNeeded() },
                apply: { preferences in self.services.changeDisplay { $0 = preferences } },
                tabs: { Array(self.tabPairs.values) + self.workspaceLayout.tabItems },
                headerActions: { [self.navigationBack, self.navigationForward, self.sidebarToggle, self.threadDetails, self.threadActions, self.tabOverflow, self.threadChanges, self.supportingToggle] + self.workspaceLayout.headerActionViews },
                surfaces: surfaces, terminal: store.state.tab(shellID), runtime: launches.runtime,
                appearanceStatus: { self.services.terminalAppearanceMessage },
                layout: { mode in self.store.update { $0.setSupportingLayout(mode) } },
                setAppearance: { appearance in self.store.update { $0.appearance = appearance } }), uniquingKeysWith: { _, new in new })
        }
        func perform(_ title: String, in menu: NSMenu) throws {
            guard let item = menu.items.first(where: { $0.title == title }), let action = item.action else { throw LaunchError.invalid("Thread action unavailable: " + title) }
            guard NSApp.sendAction(action, to: item.target, from: item) else { throw LaunchError.invalid("Thread action failed: " + title) }
        }
        let threadKey = store.state.selected!.threadKey, activeWorkspace = store.state.selectedWorkspaceID!
        try perform("Pin", in: sidebar.workspaceContextMenu(activeWorkspace))
        let pinnedKey = "pinned:" + threadKey
        checks["pin_preserves_thread_and_execution"] = store.state.presentation(for: threadKey).pinnedAt != nil && store.state.selectedWorkspaceID == activeWorkspace && store.state.tab(shellID)?.binding == binding
        conversationSidebar.onActivate?(pinnedKey)
        checks["pinned_occurrence_is_only_selected_row"] = conversationSidebar.selectedItemIDs == [pinnedKey] && store.state.selectedWorkspaceID == activeWorkspace
        try perform("Archive", in: sidebar.workspaceContextMenu(activeWorkspace))
        checks["archive_preserves_running_thread_and_reaches_composer"] = store.state.selected?.isLanding == true && store.state.workspaces.first(where: { $0.id == activeWorkspace }).map(store.state.isArchived) == true && store.state.tab(shellID)?.binding == binding
        sidebar.showingArchived = true; chromeRevision = ""; render()
        let archivedKey = "archived:" + threadKey
        if let menu = conversationSidebar.onContextMenu?(archivedKey) { try perform("Unarchive", in: menu) }
        checks["archived_row_unarchive_uses_same_identity"] = store.state.presentation(for: threadKey).archivedAt == nil && store.state.tab(shellID)?.binding == binding
        sidebar.showingArchived = false; sidebar.selectedSidebarOccurrence = nil; selectWorkspace(activeWorkspace)
        try perform("Unpin", in: sidebar.workspaceContextMenu(activeWorkspace))
        try PrivateFiles.write(resources, to: root.appendingPathComponent("sidebar-resources.json"))
        try PrivateFiles.write(interactionDetails, to: root.appendingPathComponent("sidebar-interaction-diagnostics.json"))
        try await store.flush(); try PrivateFiles.write(checks, to: root.appendingPathComponent("sidebar-checks.json"))
        guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("Sidebar fixture failed: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", ")) }
    }
    func checkActivityRecovery(root: URL, terminal: UUID) async throws -> [String: Bool] {
        guard let binding = store.state.tab(terminal)?.binding, let surface = surfaces.view(terminal) else {
            throw LaunchError.invalid("Activity recovery fixture terminal is unavailable.")
        }
        let before = try await launches.runtime.inspect(binding), input = surface.visibleText()
        activityReceiver = nil
        var otherOwner: AgentActivityReceiver? = try AgentActivityReceiver(root: root) { _ in }
        withExtendedLifetime(otherOwner) { reopen() }
        var checks = ["activity_retry_preserves_active_owner": activityReceiver == nil]
        otherOwner = nil
        setFocus(true)
        checks["activation_retries_unavailable_activity_receiver"] = activityReceiver != nil
        activityReceiver = nil; reopen()
        checks["window_reopen_retries_unavailable_activity_receiver"] = activityReceiver != nil
        let context = try AgentIntegration.read(AgentTerminalContext.self,
            path: root.appendingPathComponent("agent-terminal-" + binding.id.uuidString + ".json").path)
        let invocation = AgentInvocation(context: context, provider: .claude)
        try PrivateFiles.write(invocation, to: URL(fileURLWithPath: context.activePath))
        AgentActivitySocket.send(invocation.event(.working), socket: context.socket)
        for _ in 0..<100 {
            if store.state.tab(terminal)?.activity?.invocationID == invocation.id { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["recovered_receiver_applies_provider_socket_event"] = store.state.tab(terminal)?.activity?.state == .working &&
            store.state.tab(terminal)?.activity?.invocationID == invocation.id
        if let renderTask { await renderTask.value }
        let after = try await launches.runtime.inspect(binding)
        checks["activity_recovery_preserves_process_surface_and_input"] = before?.processID != nil &&
            before?.processID == after?.processID && surfaces.view(terminal) === surface && surface.visibleText() == input
        store.update { $0.resetAgent(terminal) }
        return checks
    }
    func runComposerFixture(root: URL) async throws {
        var checks: [String: Bool] = [:]
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let projectRoot = root.appendingPathComponent("spookky"), worktreeRoot = root.appendingPathComponent("topic")
        let detachedRoot = root.appendingPathComponent("release-checkout")
        try PrivateFiles.directory(projectRoot)
        for arguments in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"],
                          ["worktree", "add", "-b", "topic", worktreeRoot.path], ["worktree", "add", "--detach", detachedRoot.path]] {
            let result = try await ProcessRunner.asyncRun("/usr/bin/git", ["-C", projectRoot.path] + arguments)
            guard result.status == 0 else { throw LaunchError.invalid("Composer Git fixture failed") }
        }
        let local = try await locations.git.discover(projectRoot), worktree = try await locations.git.discover(worktreeRoot)
        var project = UUID()
        store.update {
            project = $0.registerProject(local)
            $0.newWorkspace(location: worktree, projectID: project)
            $0.editDraft($0.primaryTerminalID!, tool: .claude, prompt: "Previous session")
            $0.editModelSelection($0.primaryTerminalID!, selection: AgentModelSelection(model: "opus", effort: "high"))
        }
        guard let newChat = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45) else {
            throw LaunchError.invalid("New chat shortcut event unavailable")
        }
        checks["cmd_n_routes_to_new_chat"] = handleCommand(newChat)
        if let renderTask { await renderTask.value }
        await refreshSelectedRepository()
        if let renderTask { await renderTask.value }
        await Task.yield()
        guard let id = store.state.primaryTerminalID, let composer = composers[id] else { throw LaunchError.invalid("Composer did not render") }
        checks["cmd_n_inherits_project_local"] = store.state.selected?.projectID == project && store.state.selected?.directory == local.path
        checks["cmd_n_inherits_provider_and_model"] = store.state.tab(id)?.draft.tool == .claude && store.state.tab(id)?.draft.modelSelection.model == "opus"
        checks["new_session_does_not_copy_previous_prompt"] = store.state.tab(id)?.draft.isEmpty == true
        var inputDebug = ["initial_prompt": store.state.tab(id)?.draft.prompt ?? "missing", "initial_editor": composer.prompt.string,
                          "initial_images": String(store.state.tab(id)?.draft.images.count ?? -1)]
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func button(_ title: String, in view: NSView) -> NSButton? {
            descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title }
        }
        func popupButton(_ title: String) -> NSButton? {
            NSApp.windows.filter { $0 !== window && $0.isVisible }.compactMap(\.contentView)
                .flatMap(descendants).compactMap { $0 as? NSButton }.first { $0.title == title }
        }
        func waitPopup(_ title: String) async throws -> NSButton {
            for _ in 0..<200 {
                if let item = popupButton(title) { return item }
                try await Task.sleep(for: .milliseconds(10))
            }
            try PrivateFiles.write(NSApp.windows.map { popup in
                ["title": popup.title, "visible": String(popup.isVisible),
                 "buttons": popup.contentView.map { descendants($0).compactMap { ($0 as? NSButton)?.title }.joined(separator: " | ") } ?? "none"]
            }, to: root.appendingPathComponent("composer-popup-debug.json"))
            for (index, popup) in NSApp.windows.enumerated() {
                if let view = popup.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("composer-popup-\(index).png"))
                }
            }
            throw LaunchError.invalid("Composer menu item missing: " + title)
        }
        func openModels() throws {
            guard let control = descendants(composer).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel()?.hasPrefix("Choose ") == true && $0.accessibilityLabel()?.contains(" model · ") == true }) else {
                throw LaunchError.invalid("Model picker is unavailable")
            }
            control.performClick(nil)
        }
        func closeModels() {
            guard let button = popupButton("Refresh models"), let popup = button.window,
                  let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: popup.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { return }
            button.keyDown(with: escape)
        }
        func toggleNewWorktree(_ on: Bool) throws {
            if !NSApp.windows.filter({ $0.isVisible }).compactMap(\.contentView).flatMap(descendants).contains(where: { $0 is NSSwitch }) {
                descendants(composer).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Choose checkout" }?.performClick(nil)
            }
            guard let control = NSApp.windows.filter({ $0.isVisible }).compactMap(\.contentView).flatMap(descendants).compactMap({ $0 as? NSSwitch }).first else { throw LaunchError.invalid("New worktree switch missing") }
            control.state = on ? .on : .off
            control.sendAction(control.action, to: control.target)
        }
        func enter(_ modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeatKey, keyCode: 36) else { throw LaunchError.invalid("Enter event missing") }
            return event
        }
        let actualLaunch = composer.onLaunch
        var submitted = 0
        composer.onLaunch = { submitted += 1 }
        composer.focus(); composer.prompt.keyDown(with: try enter())
        checks["empty_enter_starts"] = submitted == 1
        composer.focus(); composer.prompt.insertText("Review this change", replacementRange: NSRange(location: NSNotFound, length: 0))
        composer.prompt.keyDown(with: try enter(.shift))
        composer.prompt.insertText("Keep the details", replacementRange: NSRange(location: NSNotFound, length: 0))
        inputDebug["after_shift_enter"] = composer.prompt.string
        inputDebug["draft_after_shift_enter"] = store.state.tab(id)?.draft.prompt
        try PrivateFiles.write(inputDebug, to: root.appendingPathComponent("composer-input-debug.json"))
        checks["native_prompt_accepts_text_and_newline"] = store.state.tab(id)?.draft.prompt == "Review this change\nKeep the details"
        composer.prompt.keyDown(with: try enter())
        checks["enter_starts_without_newline"] = submitted == 2 && composer.prompt.string == "Review this change\nKeep the details"
        _ = handleCommand(try enter(.command))
        checks["cmd_enter_uses_same_start_action"] = submitted == 3
        composer.prompt.keyDown(with: try enter(repeatKey: true)); _ = handleCommand(try enter(.command, repeatKey: true))
        checks["held_enter_does_not_repeat_launch"] = submitted == 3
        composer.prompt.setMarkedText("composition", selectedRange: NSRange(location: 11, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        composer.prompt.keyDown(with: try enter())
        checks["marked_text_enter_does_not_start"] = submitted == 3
        composer.prompt.unmarkText()
        composer.prompt.string = "Review this change\nKeep the details"
        composer.prompt.didChangeText()
        let send = descendants(composer).compactMap { $0 as? ActionButton }.first { $0.circular && $0.emphasis == .primary }
        send?.isEnabled = false; composer.prompt.keyDown(with: try enter()); _ = handleCommand(try enter(.command))
        checks["disabled_start_blocks_both_shortcuts"] = submitted == 3
        send?.isEnabled = true; composer.onLaunch = actualLaunch
        try openModels(); let sonnet = try await waitPopup("Sonnet"); sonnet.performClick(nil)
        checks["claude_model_menu_updates_draft"] = store.state.tab(id)?.draft.modelSelection.model == "sonnet"
        store.update { $0.editDraft(id, tool: .codex) }
        if let renderTask { await renderTask.value }
        try openModels(); let sol = try await waitPopup("Sol fixture"); sol.performClick(nil)
        let high = try await waitPopup("High"); high.performClick(nil)
        checks["codex_model_and_effort_update_draft"] = store.state.tab(id)?.draft.modelSelection == AgentModelSelection(model: "fixture-sol", effort: "high", displayName: "Sol fixture")
        checks["model_and_effort_share_open_popover"] = popupButton("Sol fixture") != nil && popupButton("High") != nil
        (try await waitPopup("Other fixture")).performClick(nil)
        if let renderTask { await renderTask.value }
        checks["different_model_uses_default_effort"] = store.state.tab(id)?.draft.modelSelection.effort == nil && popupButton("High") == nil
        (try await waitPopup("Sol fixture")).performClick(nil)
        if let renderTask { await renderTask.value }
        checks["return_to_model_recalls_effort"] = store.state.tab(id)?.draft.modelSelection.effort == "high"
        (try await waitPopup("Plain fixture")).performClick(nil)
        if let renderTask { await renderTask.value }
        checks["unsupported_effort_section_hidden"] = popupButton("Default effort") == nil
        (try await waitPopup("Sol fixture")).performClick(nil)
        if let renderTask { await renderTask.value }
        if let popup = popupButton("Sol fixture")?.window,
           let search = popup.contentView.map(descendants)?.compactMap({ $0 as? NSSearchField }).first,
           let access = popup.contentView.map(descendants)?.compactMap({ $0 as? NSSwitch }).first {
            checks["short_model_list_hides_search"] = search.isHidden && popupButton("High") != nil
            checks["full_access_starts_off"] = access.state == .off && store.state.tab(id)?.draft.fullAccess == false
            access.performClick(nil)
            checks["full_access_updates_draft"] = store.state.tab(id)?.draft.fullAccess == true
        }
        closeModels()
        await Task.yield()
        checks["model_choice_restores_composer_shortcuts"] = composer.hasInputFocus
        store.update { $0.editDraft(id, tool: .claude) }
        checks["provider_change_clears_full_access"] = store.state.tab(id)?.draft.fullAccess == false
        checks["switch_back_restores_provider_model"] = store.state.tab(id)?.draft.modelSelection.model == "sonnet"
        store.update { $0.editDraft(id, tool: .codex) }
        checks["switching_providers_keeps_prompt"] = composer.prompt.string == "Review this change\nKeep the details"
        try toggleNewWorktree(true)
        if let renderTask { await renderTask.value }
        checks["switch_selects_new_worktree"] = store.state.selected?.locationDraft?.mode == .worktree
        let from = descendants(composer).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("From ") }
        from?.performClick(nil); (try await waitPopup("main")).performClick(nil)
        checks["source_menu_selects_reference"] = store.state.selected?.locationDraft?.source == "refs/heads/main"
        let sourceBeforeToggle = store.state.selected?.locationDraft?.source
        try toggleNewWorktree(false)
        checks["local_keeps_checkout_files_and_branch"] = store.state.selected?.directory == local.path && store.state.selected?.selectedLocation.branch == "main"
        try toggleNewWorktree(true)
        checks["switch_round_trip_keeps_reference"] = store.state.selected?.locationDraft?.source == sourceBeforeToggle
        try toggleNewWorktree(false)
        if let renderTask { await renderTask.value }
        button("Local", in: composer)?.performClick(nil)
        checks["checkout_picker_only_selects_existing_files"] = popupButton("New worktree") == nil && popupButton("Local") != nil
        checks["detached_checkout_has_folder_identity"] = popupButton("release-checkout")?.accessibilityLabel()?.contains("Detached HEAD") == true
        checks["checkout_detail_is_one_interactive_row"] = (popupButton("topic") as? ActionButton)?.detail?.contains("topic") == true
        (try await waitPopup("topic")).performClick(nil)
        for _ in 0..<100 where store.state.selected?.selectedLocation.checkoutIdentity != worktree.checkoutIdentity { try await Task.sleep(for: .milliseconds(10)) }
        checks["checkout_picker_selects_existing_worktree"] = store.state.selected?.directory == worktree.path
        try toggleNewWorktree(true); try toggleNewWorktree(false)
        checks["switch_preserves_existing_checkout"] = store.state.selected?.directory == worktree.path
        if let renderTask { await renderTask.value }
        button("Existing worktree", in: composer)?.performClick(nil)
        (try await waitPopup("Local")).performClick(nil)
        for _ in 0..<100 where store.state.selected?.directory != local.path { try await Task.sleep(for: .milliseconds(10)) }
        button("spookky", in: composer)?.performClick(nil)
        (try await waitPopup("No project")).performClick(nil)
        checks["no_project_retains_prompt"] = store.state.selected?.projectID == nil && composer.prompt.string == "Review this change\nKeep the details"
        button("No project", in: composer)?.performClick(nil)
        (try await waitPopup("spookky")).performClick(nil)
        await refreshSelectedRepository()
        let emptyRoot = root.appendingPathComponent("empty-repository")
        try PrivateFiles.directory(emptyRoot)
        let emptyInit = try await ProcessRunner.asyncRun("/usr/bin/git", ["-C", emptyRoot.path, "init", "-b", "main"])
        guard emptyInit.status == 0 else { throw LaunchError.invalid("Empty repository fixture failed") }
        let emptyLocation = try await locations.git.discover(emptyRoot)
        var emptyProject = UUID()
        store.update { emptyProject = $0.registerProject(emptyLocation) }
        chooseProject(emptyProject); await refreshSelectedRepository()
        if let renderTask { await renderTask.value }
        button("Local", in: composer)?.performClick(nil)
        checks["empty_repository_disables_worktree_switch"] = NSApp.windows.filter { $0.isVisible }.compactMap(\.contentView).flatMap(descendants).compactMap { $0 as? NSSwitch }.first?.isEnabled == false
        (popupButton("Local") as? ActionButton)?.onCancel?()
        chooseProject(project); await refreshSelectedRepository()
        if let renderTask { await renderTask.value }
        checks["project_switch_preserves_prompt"] = composer.prompt.string == "Review this change\nKeep the details"
        for (theme, width, height) in [(WorkspaceAppearance.dark, 1120, 760), (.light, 1120, 760), (.dark, 680, 480), (.light, 680, 480), (.dark, 650, 450)] {
            store.update { $0.appearance = theme }
            window.setContentSize(NSSize(width: width, height: height)); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let editor = composer.convert(composer.prompt.bounds, from: composer.prompt)
            checks["composer_fits_\(theme.rawValue)_\(width)"] = editor.minX >= 23 && editor.maxX <= composer.bounds.width - 23
            let circularButtons = descendants(composer).compactMap { $0 as? ActionButton }.filter { $0.circular }
            checks["composer_circles_\(theme.rawValue)_\(width)"] = circularButtons.count == 2 && circularButtons.allSatisfy { abs($0.bounds.width - 32) < 0.5 && abs($0.bounds.height - 32) < 0.5 }
            checks["composer_has_no_keyboard_hint_\(theme.rawValue)_\(width)"] = !descendants(composer).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Enter to send") }
            checks["composer_has_compact_context_\(theme.rawValue)_\(width)"] = !descendants(composer).contains { $0 is NSSwitch }
            checks["composer_text_inset_\(theme.rawValue)_\(width)"] = composer.prompt.textContainerInset.width == 16 && composer.prompt.textContainer?.lineFragmentPadding == 0
            let heading = descendants(composer).compactMap { $0 as? NSTextField }.first { $0.stringValue == "What’s next in spookky?" }
            checks["contextual_heading_\(theme.rawValue)_\(width)"] = heading != nil
            if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let sidebar = view.convert(railScroll.bounds, from: railScroll)
                let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
                let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
                let left = Int((sidebar.minX + 12) * scaleX), right = Int((sidebar.maxX - 12) * scaleX)
                var darkest: CGFloat = 1, lightest: CGFloat = 0
                for y in stride(from: Int(80 * scaleY), to: bitmap.pixelsHigh - Int(24 * scaleY), by: 4) {
                    for x in stride(from: left, to: right, by: 4) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                        let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        darkest = min(darkest, brightness); lightest = max(lightest, brightness)
                    }
                }
                checks["composer_keeps_sidebar_pixels_\(theme.rawValue)_\(width)"] = lightest - darkest > 0.15
                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("composer-\(theme.rawValue)-\(width).png"))
            }
        }
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        func modelMenuAboveControl(_ label: String) -> Bool {
            guard let control = descendants(composer).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel()?.contains(" model · ") == true }),
                  let host = control.window, let popup = popupButton("Sol fixture")?.window else { return false }
            let controlFrame = host.convertToScreen(control.convert(control.bounds, to: nil))
            try? PrivateFiles.write(["controlTop": Double(controlFrame.maxY), "popupBottom": Double(popup.frame.minY),
                                     "popupTop": Double(popup.frame.maxY), "windowTop": Double(host.frame.maxY)],
                                    to: root.appendingPathComponent("composer-menu-geometry-" + label + ".json"))
            return popup.frame.minY >= controlFrame.maxY - 2 && popup.frame.maxY <= host.frame.maxY - 20
        }
        try openModels(); _ = try await waitPopup("Sol fixture")
        checks["model_menu_above_control_1120"] = modelMenuAboveControl("1120")
        if let view = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.contentView.map { button("Sol fixture", in: $0) != nil } == true })?.contentView,
           let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("composer-model-menu.png"))
        }
        closeModels()
        window.setContentSize(NSSize(width: 650, height: 450)); window.contentView?.layoutSubtreeIfNeeded()
        try openModels(); _ = try await waitPopup("Sol fixture")
        checks["model_menu_above_control_650"] = modelMenuAboveControl("650")
        closeModels()
        window.setContentSize(NSSize(width: 1120, height: 760)); window.contentView?.layoutSubtreeIfNeeded()
        try openModels(); _ = try await waitPopup("Sol fixture")
        (try await waitPopup("Default model")).performClick(nil)
        checks["default_model_clears_overrides"] = store.state.tab(id)?.draft.modelSelection == AgentModelSelection()
        (try await waitPopup("Sol fixture")).performClick(nil)
        if let renderTask { await renderTask.value }
        let selectionBeforeRefresh = store.state.tab(id)?.draft.modelSelection
        (try await waitPopup("Refresh models")).performClick(nil)
        _ = try await waitPopup("Model discovery unavailable")
        checks["discovery_failure_preserves_model_choice"] = store.state.tab(id)?.draft.modelSelection == selectionBeforeRefresh
        closeModels()
        let prompt = store.state.tab(id)!.draft.prompt
        guard let terminalButton = button("Open Terminal", in: composer) else { throw LaunchError.invalid("Terminal action missing") }
        terminalButton.performClick(nil)
        var terminalID: UUID?
        for _ in 0..<300 {
            if let selected = store.state.primaryTerminalID, selected != id, surfaces.view(selected) != nil { terminalID = selected; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let terminalID, let surface = surfaces.view(terminalID), let binding = store.state.tab(terminalID)?.binding else { throw LaunchError.invalid("Disposable terminal did not start") }
        let pid = try await launches.runtime.inspect(binding)?.processID
        surface.insertText("printf 'COMPOSER_%s\\n' 'READY'", replacementRange: NSRange(location: NSNotFound, length: 0))
        if let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) { surface.keyDown(with: enter) }
        for _ in 0..<200 where !surface.visibleText().contains("COMPOSER_READY") { try await Task.sleep(for: .milliseconds(20)) }
        checks["real_shell_input_and_output"] = surface.visibleText().contains("COMPOSER_READY")
        newWorkspace(); if let renderTask { await renderTask.value }
        checks["terminal_keeps_agent_draft"] = store.state.primaryTerminalID == id && store.state.tab(id)?.draft.prompt == prompt
        checks["returning_keeps_shell_process"] = try await launches.runtime.inspect(binding)?.processID == pid && pid != nil
        let sessions = try await launches.runtime.list()
        checks["menus_and_new_chat_launch_no_agents"] = sessions.count == 1 && sessions.allSatisfy { $0.tool == .shell }
        guard let landingID = store.state.selectedWorkspaceID, let landingTab = store.state.primaryTerminalID,
              let landingComposer = composers[landingTab] else { throw LaunchError.invalid("Error notice fixture has no landing composer") }
        let failedRequest = LocationRequest(kind: .worktree, destination: root.appendingPathComponent("failed-worktree").path,
            projectID: project, workspaceID: landingID, sourcePath: local.path,
            commonRepository: local.commonRepository, source: "HEAD", branch: "fixture-error")
        var failedOperation = LocationOperation(failedRequest)
        failedOperation.status = .failed
        failedOperation.error = "git-lfs filter-process: git-lfs: command not found\nfatal: the remote end hung up unexpectedly"
        store.update { state in
            var draft = state.selected!.locationDraft ?? LocationDraft(); draft.mode = .worktree
            state.editLocation(draft, workspaceID: landingID)
            state.recordOperation(failedOperation)
            state.apply(.failure(.failed, TabFailure(.validation, failedOperation.error!), clearIntent: true), to: landingTab)
        }
        if let renderTask { await renderTask.value }
        checks["worktree_error_card_scoped_to_composer"] = button("Use Local checkout", in: landingComposer) != nil && warning.isHidden
        for (theme, width, height) in [(WorkspaceAppearance.dark, 1120, 760), (.light, 650, 450)] {
            store.update { $0.appearance = theme }
            window.setContentSize(NSSize(width: width, height: height)); window.contentView?.layoutSubtreeIfNeeded()
            let card = descendants(landingComposer).compactMap { $0 as? AppErrorNoticeView }.first
            checks["error_card_fits_\(theme.rawValue)_\(width)"] = card?.isHidden == false && (card?.frame.width ?? 0) <= landingComposer.bounds.width
            if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("composer-error-\(theme.rawValue)-\(width).png"))
            }
        }
        if let shellWorkspaceID = store.state.workspace(containing: terminalID)?.id {
            selectWorkspace(shellWorkspaceID)
            if let renderTask { await renderTask.value }
            checks["unrelated_terminal_has_no_worktree_error_footer"] = warning.isHidden && store.state.selectedWorkspaceID == shellWorkspaceID
            selectWorkspace(landingID)
            if let renderTask { await renderTask.value }
        }
        button("Dismiss", in: landingComposer)?.performClick(nil)
        checks["error_dismissal_retains_failed_operation"] = store.state.locations?.operations.first(where: { $0.id == failedRequest.id })?.noticeDismissed == true &&
            store.state.locations?.operations.first(where: { $0.id == failedRequest.id })?.status == .failed
        store.update { state in
            failedOperation.noticeDismissed = nil; state.recordOperation(failedOperation)
            state.apply(.failure(.failed, TabFailure(.validation, failedOperation.error!), clearIntent: true), to: landingTab)
        }
        if let renderTask { await renderTask.value }
        button("Use Local checkout", in: landingComposer)?.performClick(nil)
        let sessionsAfterLocal = try await launches.runtime.list()
        checks["error_local_action_preserves_prompt"] = store.state.selected?.locationDraft?.mode == .local &&
            store.state.tab(landingTab)?.status == .draft && sessionsAfterLocal.count == sessions.count &&
            store.state.tab(landingTab)?.draft.prompt == prompt &&
            store.state.locations?.operations.first(where: { $0.id == failedRequest.id })?.status == .failed
        try await store.flush()
        try PrivateFiles.write(checks, to: root.appendingPathComponent("composer-checks.json"))
        try PrivateFiles.write(["app_rss_mib": WorkspaceDiagnostics.residentMiB() ?? 0, "runtime_sessions": Double(sessions.count)], to: root.appendingPathComponent("composer-resources.json"))
        guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("Composer checks failed: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", ")) }
    }
    func recordBenchmarkQuit(_ phase: String, context: [String: String] = [:]) {
        guard ApplicationArguments.values.contains("--workspace-benchmark-continuity") else { return }
        let event = context.merging(["phase": phase, "time": Date().ISO8601Format(),
            "appActive": String(NSApp.isActive), "windowKey": String(window.isKeyWindow)], uniquingKeysWith: { _, new in new })
        fixtureQuitRequests = Array((fixtureQuitRequests + [event]).suffix(16))
        try? PrivateFiles.write(fixtureQuitRequests, to: activityRoot.appendingPathComponent("quit-requests.json"))
    }
    func recordBenchmarkFailure(root: URL) {
        guard diagnostics != nil, ApplicationArguments.values.contains("--workspace-benchmark-continuity") else { return }
        struct Tab: Encodable {
            let id: UUID
            let bindingID: UUID?
            let status: String
            let failure: String?
            let surface: Bool
        }
        struct Failure: Encodable {
            let selectedTab: UUID?
            let visibleTabs: [UUID]
            let windowVisible: Bool
            let windowKey: Bool
            let appActive: Bool
            let closeRequests: [[String: String]]
            let tabs: [Tab]
        }
        let snapshot = Failure(selectedTab: store.state.selectedTab?.id, visibleTabs: store.state.visibleTabIDs,
            windowVisible: window.isVisible, windowKey: window.isKeyWindow, appActive: NSApp.isActive,
            closeRequests: fixtureCloseRequests, tabs: store.state.workspaces.flatMap(\.tabs).prefix(32).map {
                Tab(id: $0.id, bindingID: $0.binding?.id, status: $0.status.rawValue,
                    failure: $0.failure.map { String($0.message.prefix(512)) }, surface: surfaces.view($0.id) != nil)
            })
        try? PrivateFiles.write(snapshot, to: root.appendingPathComponent("continuity-failure.json"))
    }
    func benchmark(count: Int, root: URL, timing: Bool) async throws {
        let fileFixture = ApplicationArguments.values.contains("--workspace-benchmark-files")
        let conversationFixture = ApplicationArguments.values.contains("--workspace-benchmark-conversations")
        if conversationFixture { store.update { $0.changeDirectory(root.path) } }
        if fileFixture {
            let location = try await GitRepository().discover(root.appendingPathComponent("code"))
            if let id = store.state.selectedWorkspaceID {
                store.update { $0.setLocation(location, projectID: nil, workspaceID: id) }
            }
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-races") { store.update { $0.changeDirectory(root.path) } }
        var ids: [UUID] = []
        for _ in 0..<count {
            var id: UUID?
            store.update {
                if ids.isEmpty { id = $0.selectedTab?.id }
                else if conversationFixture {
                    $0.newWorkspace(directory: root.path)
                    id = $0.primaryTerminalID
                } else { id = $0.newTab() }
            }
            guard let id else { throw LaunchError.invalid("Benchmark tab is unavailable.") }
            await launches.launch(id, tool: .shell)
            guard store.state.tab(id)?.binding != nil else { throw LaunchError.invalid("Benchmark launch failed.") }
            ids.append(id)
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-recovery") {
            let selected = store.state.selectedWorkspaceID
            store.update {
                $0.newWorkspace(directory: root.path)
                if let draft = $0.primaryTerminalID { $0.editDraft(draft, tool: .codex, prompt: "SPOOKKY_UNSENT_COMPOSER_RECOVERY") }
                if let selected { $0.selectWorkspace(selected) }
            }
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-activity") {
            services.agentPreferences.inputSound = false; services.agentPreferences.finishedSound = false; services.agentPreferences.failedSound = false
            await agentPreferencesTask?.value
            if let first = ids.first { store.update { $0.selectTab(first) } }
            if let renderTask { await renderTask.value }
            for (index, id) in ids.enumerated() {
                guard let binding = store.state.tab(id)?.binding else { continue }
                let path = root.appendingPathComponent("agent-terminal-" + binding.id.uuidString + ".json")
                let context = try AgentIntegration.read(AgentTerminalContext.self, path: path.path)
                let invocation = AgentInvocation(context: context, provider: index % 2 == 0 ? .codex : .claude)
                try PrivateFiles.write(invocation, to: URL(fileURLWithPath: invocation.path))
                try PrivateFiles.write(invocation, to: URL(fileURLWithPath: context.activePath))
                AgentActivitySocket.send(invocation.event(.attached), socket: context.socket)
                AgentActivitySocket.send(invocation.event([.working, .needsInput, .finished, .failed, .unsupported][index % 5]), socket: context.socket)
            }
            try await Task.sleep(for: .milliseconds(350))
            let snapshot = store.state.workspaces.flatMap(\.tabs).compactMap { tab -> [String: String]? in
                guard let activity = tab.activity else { return nil }
                return ["tabID": tab.id.uuidString, "state": activity.displayState.rawValue, "unread": String(activity.unread)]
            }
            try PrivateFiles.write(snapshot, to: root.appendingPathComponent("activity-fixture.json"))
        }
        try await store.flush()
        if let renderTask { await renderTask.value }
        if ApplicationArguments.values.contains("--workspace-benchmark-split"), ids.count >= 2 {
            store.update { $0.setSplit(first: ids[0], second: ids[1]) }
            if let renderTask { await renderTask.value }
        }
        if fileFixture, let id = store.state.selectedWorkspaceID {
            var view = FileViewState(); view.sidebar = true; view.changes = true
            view.preview = true; view.selectedPath = "sample.swift"; view.selectedGroup = "Unstaged"
            store.update {
                $0.setFileView(view, workspaceID: id)
                $0.openSupport(.changes, title: "Changes", workspaceID: id)
            }
            if let renderTask { await renderTask.value }
            await files.settleForFixture()
            if ApplicationArguments.values.contains("--workspace-benchmark-diffs") {
                var samples: [Double] = [], counts: [[String: Int]] = [], phases: [[String: Double]] = []
                var otherID: UUID?
                store.update { otherID = $0.newWorkspace(directory: root.appendingPathComponent("other").path); $0.selectWorkspace(id) }
                for index in 0..<135 {
                    if index >= 35, let otherID {
                        store.update { $0.selectWorkspace(otherID) }; if let renderTask { await renderTask.value }
                        store.update { $0.selectWorkspace(id) }; if let renderTask { await renderTask.value }
                        await files.settleForFixture()
                    }
                    let path = index >= 35 && index % 2 == 0 ? "other.swift" : "sample.swift"
                    let elapsed = try await files.previewForFixture(path: path, group: "Unstaged", split: index >= 35 && index % 3 == 0, waitForSyntax: index < 35)
                    if index >= 5 && index < 35 { samples.append(elapsed); phases.append(files.previewTimings) }
                    if index == 34 {
                        try PrivateFiles.write(samples, to: root.appendingPathComponent("file-timings.json"))
                        try PrivateFiles.write(phases, to: root.appendingPathComponent("file-phases.json"))
                    }
                    if index >= 35 { counts.append(files.diagnostics.merging(["surfaces": surfaces.count], uniquingKeysWith: { _, new in new })) }
                }
                await files.settleSyntaxForFixture()
                let surface = store.state.selectedTab.flatMap { surfaces.view($0.id) }
                surface?.insertText("SPOOKKY_M3_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
                var interactions = try await files.interactionChecksForFixture()
                interactions["terminal_draft_preserved"] = surface?.visibleText().contains("SPOOKKY_M3_UNSENT") == true
                try PrivateFiles.write(interactions, to: root.appendingPathComponent("file-interactions.json"))
                try PrivateFiles.write(samples, to: root.appendingPathComponent("file-timings.json"))
                try PrivateFiles.write(counts, to: root.appendingPathComponent("file-cycles.json"))
            }
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-races"), let id = ids.first {
            try await surfaceRaceFixture(id: id, root: root)
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-selection"), let id = ids.first,
           let view = surfaces.view(id), let binding = store.state.tab(id)?.binding {
            try await TerminalSelectionFixture.run(view: view, binding: binding, runtime: launches.runtime, root: root)
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-project-association") {
            guard count == 0 else { throw LaunchError.invalid("Project association fixture starts with no running sessions.") }
            try await checkProjectAssociation(root: root)
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-identity") {
            guard count == 0 else { throw LaunchError.invalid("Identity fixtures start without running sessions.") }
            try await checkConversationIdentity(root: root)
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-history") {
            try await runHistorySidebarFixture(root: root)
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-sidebar") {
            guard count == 0 else { throw LaunchError.invalid("Sidebar fixtures start without running sessions.") }
            try await checkSidebar(root: root)
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-prompt-images") {
            guard count == 0 else { throw LaunchError.invalid("Prompt image checks require no running sessions.") }
            store.update {
                _ = $0.showLanding(homeDirectory: root.path)
                $0.editDraft($0.primaryTerminalID!, tool: .codex, prompt: "Explain this screenshot")
            }
            if let renderTask { await renderTask.value }
            guard let id = store.state.primaryTerminalID, let composer = composers[id] else {
                throw LaunchError.invalid("Prompt image composer is unavailable.")
            }
            try await PromptImageFixture.run(composer: composer, window: window, root: root,
                draft: { self.store.state.tab(id)!.draft }, changeTool: { tool in self.store.update { $0.editDraft(id, tool: tool) } })
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-composer") {
            guard count == 0 else { throw LaunchError.invalid("Composer checks require no running sessions.") }
            try await runComposerFixture(root: root)
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-sidebar-reference") {
            guard count == 0 else { throw LaunchError.invalid("Sidebar reference fixtures start without running sessions.") }
            let previousAppearance = store.state.appearance
            defer { store.update { $0.appearance = previousAppearance } }
            try await SidebarReferenceFixture.run(window: window, root: root,
                setAppearance: { appearance in self.store.update { $0.appearance = appearance } })
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-browser") {
            guard count == 0, let host = supportingContentHost as? BrowserArtifactContentHost else { throw LaunchError.invalid("Browser fixtures require no launched sessions.") }
            try await SupportingPreviewFixture.run(window: window, host: host, state: { self.store.state },
                mutate: { change in self.store.update(change) }, command: { self.handleCommand($0) },
                submitAddress: { id, input in self.startPages[id]?.onAddress?(input) },
                openTerminal: { if let id = self.store.state.primaryTerminalID { self.openTerminal(from: id) } },
                terminal: { self.store.state.primaryTerminalID.flatMap { self.surfaces.view($0) } }, runtime: launches.runtime, root: root)
            try await store.flush()
        }
        if ApplicationArguments.values.contains("--workspace-benchmark-close") {
            guard count == 0 else { throw LaunchError.invalid("Close fixtures start with one unlaunched tab.") }
            let fixtureHost = SupportingContentFixtureHost(); supportingContentHost = fixtureHost
            try await WorkspaceCloseFixture.run(window: window, state: { self.store.state }, runtime: launches.runtime,
                view: { self.surfaces.view($0) }, command: { self.handleCommand($0) }, reopen: { self.reopen() },
                openTerminal: { if let id = self.store.state.primaryTerminalID { self.openTerminal(from: id) } },
                landingFocused: { self.store.state.primaryTerminalID.flatMap { self.composers[$0] }?.hasInputFocus == true },
                openBrowser: { id in self.store.update { $0.updateSupport(id, target: .browser(url: "about:blank"), title: "Browser") }; self.focusSupportingContent() },
                supportingView: { self.workspaceLayout.panel }, selectWorkspace: { id in self.store.update { $0.selectWorkspace(id) } },
                openSupportingTerminal: { if let id = self.store.state.primaryTerminalID { self.openTerminal(from: id) } },
                reopenSupportingTerminal: { id in
                    self.store.update { $0.openSupport(.startPage, title: "New tab") }
                    self.renderSupportingContent()
                    @MainActor func button(_ view: NSView) -> NSButton? {
                        if view.identifier?.rawValue == "reopen-terminal:" + id.uuidString { return view as? NSButton }
                        return view.subviews.lazy.compactMap { button($0) }.first
                    }
                    if let page = self.workspaceLayout.panel.subviews.first { button(page)?.performClick(nil) }
                },
                prepareStop: { self.store.update { state in if let id = state.selectedWorkspaceID { state.associateConversation(ConversationID(provider: .codex, sessionID: "disposable-stop-fixture"), workspaceID: id) } } },
                stop: { self.stopPrimaryAgent() }, setAppearance: { appearance in self.store.update { $0.appearance = appearance } },
                support: { id, layout in self.store.update { state in if let id { state.selectSupport(id) }; if let layout { state.setSupportingLayout(layout) } } },
                host: fixtureHost,
                settled: { self.closing.isEmpty && !self.store.state.workspaces.flatMap(\.tabs).contains { self.launches.isBusy($0.id) } }, root: root)
            try await store.flush()
        }
        if let index = ApplicationArguments.values.firstIndex(of: "--workspace-benchmark-continuity") {
            guard ApplicationArguments.values.count > index + 1,
                  let seconds = Int(ApplicationArguments.values[index + 1]), (1...28800).contains(seconds), ids.count == 10 else {
                throw LaunchError.invalid("Continuity requires ten fixture sessions and a duration from 1 to 28800 seconds.")
            }
            try await continuityFixture(ids: ids, root: root, seconds: seconds)
        }
        let observations = try await launches.runtime.list()
        var pids: [UUID: Int32] = [:]
        for binding in observations { pids[binding.id] = try await launches.runtime.inspect(binding)?.processID }
        if timing && ids.count >= 4 {
            var warmSwitches: [Double] = [], recreatedSwitches: [Double] = []
            func selectFixtureTerminal(_ id: UUID) async throws {
                let warm = surfaces.view(id) != nil
                let started = ProcessInfo.processInfo.systemUptime
                store.update { state in
                    if conversationFixture, let workspace = state.workspace(containing: id) { state.selectWorkspace(workspace.id) }
                    state.selectTab(id)
                }
                if let renderTask { await renderTask.value }
                guard surfaces.view(id) != nil else { throw LaunchError.invalid("Benchmark attachment failed.") }
                let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                if warm { warmSwitches.append(elapsed) } else { recreatedSwitches.append(elapsed) }
            }
            for index in 0..<40 {
                try await selectFixtureTerminal(ids[index % 2])
            }
            let cycleCount = try WorkspaceBenchmarkOptions.cycleCount()
            for index in 0..<cycleCount {
                let id = ids[index % ids.count]
                try await selectFixtureTerminal(id)
            }
            if conversationFixture {
                try PrivateFiles.write(["warm": warmSwitches, "recreated": recreatedSwitches],
                                       to: root.appendingPathComponent("conversation-selection-timings.json"))
            }
            for binding in observations {
                guard try await launches.runtime.inspect(binding)?.processID == pids[binding.id] else { throw LaunchError.invalid("Benchmark process identity changed.") }
            }
            let id = ids[0]
            try await selectFixtureTerminal(id)
            guard let view = surfaces.view(id) else { throw LaunchError.invalid("Fixture surface is unavailable.") }
            let fixtureCommand = ApplicationArguments.values.contains("--workspace-benchmark-resize")
                ? "for i in {1..150}; do printf 'SPOOKKY_M1_FIXTURE_HISTORY_%s %0120d\\n' $i 0; done"
                : "for i in {1..150}; do echo SPOOKKY_M1_FIXTURE_HISTORY_$i; done"
            view.insertText(fixtureCommand, replacementRange: NSRange(location: NSNotFound, length: 0))
            guard let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { throw LaunchError.invalid("Fixture Enter event is unavailable.") }
            view.keyDown(with: enter)
            var outputReady = false
            for _ in 0..<100 {
                if view.visibleText().contains("SPOOKKY_M1_FIXTURE_HISTORY_150") { outputReady = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard outputReady else { throw LaunchError.invalid("Fixture command did not produce its expected terminal output.") }
            try await surfaces.scrollFixtureHistory(id, offset: ApplicationArguments.values.contains("--workspace-benchmark-resize") ? nil : 25)
            var marker: Int?
            for _ in 0..<100 {
                marker = surfaces.fixtureHistoryMarker(id)
                if let marker, marker < 100 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard let marker, marker < 100 else {
                throw LaunchError.invalid("Fixture viewport did not become ready. Fixture screen: " + String(view.visibleText().prefix(1200)))
            }
            if ApplicationArguments.values.contains("--workspace-benchmark-resize") {
                let original = window.frame
                let expectedAnchor = store.state.tab(id)?.viewport?.anchor?.digest
                var checks: [String: Bool] = [:]
                for (name, size) in [("narrow", NSSize(width: 760, height: 570)), ("wide", NSSize(width: 1240, height: 850))] {
                    window.setFrame(NSRect(origin: original.origin, size: size), display: true)
                    body.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    for _ in 0..<100 {
                        if !surfaces.isResizing(id) { break }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    let observed = try await surfaces.observedViewport(id)
                    checks[name + "_wrapped_anchor"] = expectedAnchor != nil && observed?.anchor?.digest == expectedAnchor && !surfaces.isResizing(id)
                }
                window.setFrame(original, display: true)
                try await Task.sleep(for: .milliseconds(500))
                try PrivateFiles.write(checks, to: root.appendingPathComponent("resize-checks.json"))
                guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("Wrapped viewport resize check failed.") }
            }
            try await store.flush()
            try PrivateFiles.write(["expected_history_marker": marker], to: root.appendingPathComponent("fixture-history.json"))
        }
        try PrivateFiles.write(["pid": ProcessInfo.processInfo.processIdentifier, "session_count": Int32(observations.count),
                                "surface_count": Int32(surfaces.count), "workspace_count": Int32(store.state.workspaces.count)],
                               to: root.appendingPathComponent("ready.json"))
    }
    func surfaceRaceFixture(id: UUID, root: URL) async throws {
        guard let owner = launches.runtime as? WorkspaceViewportFixtureRuntime,
              let view = surfaces.view(id) else { throw LaunchError.invalid("Race fixture is unavailable") }
        view.insertText("for i in {1..150}; do echo SPOOKKY_M4_RACE_$i; done", replacementRange: NSRange(location: NSNotFound, length: 0))
        guard let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { throw LaunchError.invalid("Fixture Enter is unavailable") }
        view.keyDown(with: enter)
        for _ in 0..<100 {
            if view.visibleText().contains("SPOOKKY_M4_RACE_150") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await surfaces.scrollFixtureHistory(id)
        try await store.flush()
        guard let binding = store.state.tab(id)?.binding else { throw LaunchError.invalid("Fixture binding is unavailable") }
        guard let before = try await launches.runtime.inspect(binding)?.processID else { throw LaunchError.invalid("Fixture process is missing") }
        await owner.holdViewport(after: 2)
        let original = window.frame
        window.setFrame(NSRect(origin: original.origin, size: NSSize(width: 760, height: 570)), display: true)
        body.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            if await owner.isHeld { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await owner.isHeld else { throw LaunchError.invalid("Resize fixture did not reach its delayed query") }
        surfaces.release(id)
        await owner.resume()
        for _ in 0..<100 {
            if surfaces.resizeTaskCount == 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let resizeSafe = surfaces.count == 0 && surfaces.resizeTaskCount == 0 && store.state.tab(id)?.status == .running
        window.setFrame(original, display: true)
        await owner.holdRestoration()
        contentKey = ""; render()
        for _ in 0..<100 {
            if await owner.isHeld { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard await owner.isHeld else { throw LaunchError.invalid("Restoration fixture did not reach its delayed result") }
        let restoration = renderTask
        surfaces.invalidate(); surfaces.release(id)
        await owner.resume()
        if let restoration { await restoration.value }
        let restoreSafe = surfaces.count == 0 && surfaces.resizeAnchorCount == 0
        contentKey = ""; render()
        if let renderTask { await renderTask.value }
        let checks = ["released_surface_not_read_after_await": resizeSafe,
            "released_restoration_not_cached": restoreSafe,
            "same_process": before == (try await launches.runtime.inspect(binding)?.processID),
            "new_surface_attached": surfaces.view(id) != nil]
        try PrivateFiles.write(checks, to: root.appendingPathComponent("surface-races.json"))
        guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("Surface race fixture failed") }
    }
    func continuityFixture(ids: [UUID], root: URL, seconds: Int) async throws {
        struct Cycle: Codable {
            let index: Int
            let warmup: Bool
            let surfaces: Int
            let watchers: Int
            let previewBytes: Int
            let metadataBytes: Int
            let composers: Int
            let fileTaskHandles: Int
            let resizeTaskHandles: Int
            let launchOperations: Int
            let rssMiB: Double
            let closedProcessGone: Bool
            let remainingSessions: Int
        }
        var cycles: [Cycle] = []
        guard let anchor = store.state.selectedWorkspaceID else { throw LaunchError.invalid("Fixture workspace is unavailable") }
        var identities: [UUID: Int32] = [:]
        var baseline: [[String: String]] = []
        for id in ids {
            guard let binding = store.state.tab(id)?.binding,
                  let observed = try await launches.runtime.inspect(binding) else { throw LaunchError.invalid("Fixture session is unavailable") }
            identities[id] = observed.processID
            baseline.append(["id": id.uuidString, "pid": String(observed.processID), "bindingID": binding.id.uuidString])
        }
        try PrivateFiles.write(baseline, to: root.appendingPathComponent("baseline-identities.json"))
        let cycleCount = try WorkspaceBenchmarkOptions.cycleCount()
        for index in 0..<cycleCount {
            var workspaceID: UUID?, tabID: UUID?
            store.update {
                workspaceID = $0.newWorkspace(directory: root.appendingPathComponent("other").path)
                tabID = $0.selectedTab?.id
            }
            guard let workspaceID, let tabID else { throw LaunchError.invalid("Cycle draft was not created") }
            await launches.launch(tabID, tool: .shell)
            if let renderTask { await renderTask.value }
            guard let binding = store.state.tab(tabID)?.binding,
                  let observation = try await launches.runtime.inspect(binding) else { throw LaunchError.invalid("Cycle launch failed") }
            store.update { $0.selectWorkspace(workspaceID) }
            var pair: UUID?
            store.update { pair = $0.newTab() }
            guard let pair else { throw LaunchError.invalid("Cycle split draft is unavailable") }
            await launches.launch(pair, tool: .shell)
            store.update { $0.setSplit(first: tabID, second: pair) }
            if let renderTask { await renderTask.value }
            guard let pairBinding = store.state.tab(pair)?.binding,
                  let pairObservation = try await launches.runtime.inspect(pairBinding) else { throw LaunchError.invalid("Cycle split launch failed") }
            guard surfaces.count <= 3 else { throw LaunchError.invalid("Cycle surface budget exceeded") }
            try await settleRuntimeForFixture()
            try await launches.terminate(pair); surfaces.release(pair)
            store.update { $0.closeTab(pair) }
            try await settleRuntimeForFixture()
            try await launches.terminate(tabID); surfaces.release(tabID)
            store.update { $0.closeWorkspace(workspaceID); $0.selectWorkspace(anchor); $0.selectTab(ids[index % ids.count]) }
            if let renderTask { await renderTask.value }
            await files.settleForFixture()
            try await store.flush()
            var gone = false
            for _ in 0..<50 {
                let firstGone = kill(observation.processID, 0) != 0 && errno == ESRCH
                let secondGone = kill(pairObservation.processID, 0) != 0 && errno == ESRCH
                if firstGone && secondGone { gone = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let remaining = try await launches.runtime.list().count
            try await settleRuntimeForFixture()
            let diagnostics = files.diagnostics
            guard let residentMiB = WorkspaceDiagnostics.residentMiB() else { throw LaunchError.invalid("Fixture RSS could not be measured") }
            cycles.append(Cycle(index: index, warmup: index < 10, surfaces: surfaces.count,
                watchers: diagnostics["watchers"] ?? 0, previewBytes: diagnostics["previewBytes"] ?? 0,
                metadataBytes: diagnostics["metadataBytes"] ?? 0, composers: composers.count,
                fileTaskHandles: diagnostics["fileTaskHandles"] ?? 0, resizeTaskHandles: surfaces.resizeTaskCount,
                launchOperations: store.state.workspaces.flatMap(\.tabs).filter { launches.isBusy($0.id) }.count,
                rssMiB: residentMiB, closedProcessGone: gone, remainingSessions: remaining))
            try PrivateFiles.write(cycles, to: root.appendingPathComponent("continuity-cycles.json"))
            guard gone, remaining == ids.count else { throw LaunchError.invalid("Cycle retained a closed process") }
        }
        store.update { $0.selectTab(ids[0]) }
        if let renderTask { await renderTask.value }
        guard let draftView = surfaces.view(ids[0]) else { throw LaunchError.invalid("Draft surface is unavailable") }
        draftView.insertText("SPOOKKY_M4_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        let delayIndex = ApplicationArguments.values.firstIndex(of: "--workspace-benchmark-output-delay")
        let outputDelay = delayIndex.flatMap { ApplicationArguments.values.indices.contains($0 + 1) ? Double(ApplicationArguments.values[$0 + 1]) : nil } ?? 0
        guard outputDelay.isFinite, (0...5).contains(outputDelay) else { throw LaunchError.invalid("Invalid fixture output delay") }
        let producer = "import time; time.sleep(\(outputDelay)); i=0\nwhile True:\n print('SPOOKKY_M4_OUTPUT_'+str(i),flush=True);i+=1;time.sleep(1)"
        let spec = try LaunchSpec(tool: .shell, executable: "/usr/bin/python3", arguments: ["-u", "-c", producer], directory: root.path)
        var outputID: UUID?
        store.update { outputID = $0.newTab() }
        guard let outputID else { throw LaunchError.invalid("Output draft is unavailable") }
        store.update { $0.apply(.preparing, to: outputID); $0.apply(.intent(spec, .none), to: outputID) }
        try await store.flush()
        let outputBinding = try await launches.runtime.create(spec)
        store.update { $0.apply(.observed(outputBinding, dead: false, exitCode: nil, prompt: PromptDelivery.none), to: outputID) }
        store.update { $0.selectTab(outputID) }
        if let renderTask { await renderTask.value }
        let outputStarted = ContinuousClock.now
        var outputReady = false
        while outputStarted.duration(to: .now) < .seconds(10) {
            if surfaces.view(outputID)?.visibleText().contains("SPOOKKY_M4_OUTPUT_") == true { outputReady = true; break }
            guard try await launches.runtime.inspect(outputBinding)?.dead == false else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard outputReady else { throw LaunchError.invalid("Continuous output fixture did not become ready within ten seconds") }
        let readiness = outputStarted.duration(to: .now).components
        try PrivateFiles.write(["milliseconds": Double(readiness.seconds) * 1000 + Double(readiness.attoseconds) / 1e15,
                                "injected_delay_seconds": outputDelay], to: root.appendingPathComponent("output-ready.json"))
        let started = ContinuousClock.now
        var checkpoints: [[String: Int]] = [], tick = 0
        while started.duration(to: .now) < .seconds(seconds) {
            store.update { $0.selectTab(ids[tick % ids.count]) }
            if let renderTask { await renderTask.value }
            if tick % 4 == 0 { surfaces.release(ids[tick % ids.count]); contentKey = ""; render(); if let renderTask { await renderTask.value } }
            if tick % 3 == 0 {
                let file = root.appendingPathComponent("code/sample.swift")
                let handle = try FileHandle(forWritingTo: file)
                try handle.seekToEnd(); try handle.write(contentsOf: Data("// SPOOKKY_M4_EDIT_\(tick)\n".utf8)); try handle.close()
                await files.settleForFixture()
            }
            store.update { $0.selectTab(outputID) }
            if let renderTask { await renderTask.value }
            var outputVisible = false
            for _ in 0..<50 {
                if surfaces.view(outputID)?.visibleText().contains("SPOOKKY_M4_OUTPUT_") == true { outputVisible = true; break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let outputObservation = try await launches.runtime.inspect(outputBinding)
            guard outputVisible, outputObservation?.dead == false else {
                let screen = String((surfaces.view(outputID)?.visibleText() ?? "NO_SURFACE").prefix(1000))
                throw LaunchError.invalid("Continuous output fixture failed. Visible: \(outputVisible), dead: \(String(describing: outputObservation?.dead)), exit: \(String(describing: outputObservation?.exitCode)). Generated fixture screen: " + screen)
            }
            if tick % 10 == 0 {
                window.performClose(nil)
                for _ in 0..<100 {
                    if surfaces.count == 0 { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard surfaces.count == 0 else { throw LaunchError.invalid("Window close retained terminal surfaces") }
                reopen()
            }
            store.update { $0.selectTab(ids[0]) }
            if let renderTask { await renderTask.value }
            var preserved = false
            for _ in 0..<50 {
                // The native text projection includes soft-wrap newlines. Confirm the owner's joined lines too.
                let visible = surfaces.view(ids[0])?.visibleText().replacingOccurrences(of: "\n", with: "") ?? ""
                if visible.contains("SPOOKKY_M4_UNSENT"), let binding = store.state.tab(ids[0])?.binding,
                   try await launches.runtime.inspect(binding) != nil {
                    let owner = try await ProcessRunner.asyncRun(PackagedRuntime.tmux(),
                        ["-S", root.appendingPathComponent("socket").path, "capture-pane", "-p", "-J", "-t", "=" + binding.name + ":0.0"], outputLimit: 8192)
                    if owner.status == 0 && owner.output.contains("SPOOKKY_M4_UNSENT") { preserved = true; break }
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard preserved else {
                try PrivateFiles.write(["visible": surfaces.view(ids[0])?.visibleText() ?? "NO_SURFACE"], to: root.appendingPathComponent("draft-failure.json"))
                throw LaunchError.invalid("Unsent fixture input was lost")
            }
            for id in ids {
                guard let binding = store.state.tab(id)?.binding,
                      try await launches.runtime.inspect(binding)?.processID == identities[id] else { throw LaunchError.invalid("Continuity process identity changed") }
            }
            checkpoints.append(files.diagnostics.merging(["tick": tick, "elapsedSeconds": Int(started.duration(to: .now).components.seconds), "surfaces": surfaces.count,
                "windowKey": window.isKeyWindow ? 1 : 0, "windowMain": window.isMainWindow ? 1 : 0,
                "resizeTaskHandles": surfaces.resizeTaskCount, "reconciliationTaskHandles": observationTask == nil ? 0 : 1,
                "renderTaskHandles": renderTask == nil ? 0 : 1], uniquingKeysWith: { _, new in new }))
            try PrivateFiles.write(checkpoints, to: root.appendingPathComponent("continuity-checkpoints.json"))
            guard surfaces.count <= 3 else { throw LaunchError.invalid("Continuity surface budget exceeded") }
            guard !backgroundFixture || (!window.isKeyWindow && !window.isMainWindow) else {
                throw LaunchError.invalid("Background fixture took native window focus.")
            }
            tick += 1
            try await Task.sleep(for: .seconds(min(15, seconds)))
        }
        try await settleRuntimeForFixture()
        try await launches.terminate(outputID); surfaces.release(outputID)
        store.update { $0.closeTab(outputID); $0.selectTab(ids[0]) }
        if let renderTask { await renderTask.value }
        try await store.flush()
        try PrivateFiles.write(["same_processes": 1, "draft_preserved": 1, "cycles": cycles.count,
            "checkpoints": checkpoints.count, "elapsedSeconds": Int(started.duration(to: .now).components.seconds)] as [String: Int], to: root.appendingPathComponent("continuity-result.json"))
    }
    func settleRuntimeForFixture() async throws {
        for _ in 0..<100 {
            if observationTask == nil && !store.state.workspaces.flatMap(\.tabs).contains(where: { launches.isBusy($0.id) }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw LaunchError.invalid("Fixture runtime reconciliation did not settle within two seconds.")
    }
}

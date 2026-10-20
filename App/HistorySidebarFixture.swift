import AppKit
import SpookkyCore
import SpookkyWorkspace
import SpookkyRuntime

actor SyntheticHistoryCatalog: SessionCatalogReading {
    let root: URL
    init(root: URL) { self.root = root }

    private func metadata(_ index: Int) -> ConversationMetadata {
        ConversationMetadata(id: ConversationID(provider: .codex, sessionID: String(format: "00000000-0000-4000-8000-%012d", index)),
            title: index == 0 ? "Needle oldest conversation" : String(format: "Conversation %04d", index),
            directory: root.appendingPathComponent(index < 300 ? "history-checkout" : "history-other-checkout").path,
            updatedAt: Date(timeIntervalSince1970: Double(index)))
    }

    func refresh(force: Bool) async -> SessionCatalogSnapshot {
        try? PrivateFiles.write(["legacy_refresh_called": true], to: root.appendingPathComponent("history-legacy-refresh.json"))
        return SessionCatalogSnapshot(conversations: (0..<600).map(metadata))
    }

    func page(query: HistoryQuery, force: Bool) async -> HistoryPage {
        let offset = max(0, Int(query.cursor ?? "0") ?? 0)
        var skipped = 0, entries: [ConversationMetadata] = []
        for index in stride(from: 599, through: 0, by: -1) {
            let item = metadata(index)
            let inDirectory = query.directories.isEmpty || query.directories.contains {
                item.directory == $0 || (!query.exactDirectories && item.directory.hasPrefix($0 == "/" ? "/" : $0 + "/"))
            }
            let matches = query.search.isEmpty || item.displayTitle.localizedCaseInsensitiveContains(query.search) ||
                (!query.titleSearchOnly && [item.directory, item.id.sessionID].contains { $0.localizedCaseInsensitiveContains(query.search) })
            guard inDirectory && matches else { continue }
            if skipped < offset { skipped += 1; continue }
            entries.append(item)
            if entries.count > query.limit { break }
        }
        let more = entries.count > query.limit
        return HistoryPage(conversations: Array(entries.prefix(query.limit)), nextCursor: more ? String(offset + query.limit) : nil)
    }
}

struct HistoryFixtureResolver: ExecutableResolver {
    let root: URL
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        if tool == .shell { return try await WorkspaceBenchmarkResolver().resolve(tool, directory: directory, prompt: prompt) }
        return try LaunchSpec(tool: tool, executable: root.appendingPathComponent("fixture-codex").path, directory: directory,
            environment: ["PATH": "/usr/bin:/bin", "HISTORY_FIXTURE_RUNS": root.appendingPathComponent("resume-runs.jsonl").path])
    }
}

extension WorkspaceWindowController {
    @MainActor func runHistorySidebarFixture(root: URL) async throws {
        guard root.path.hasPrefix("/tmp/spookky-m1-"), ProcessInfo.processInfo.environment["SPOOKKY_M1_DATA"] != nil,
              let persistence = store.historyPersistence else { throw LaunchError.invalid("History fixture requires isolated persistent state.") }
        let checkout = root.appendingPathComponent("history-checkout")
        let otherCheckout = root.appendingPathComponent("history-other-checkout")
        try PrivateFiles.directory(checkout); try PrivateFiles.directory(otherCheckout)
        let script = #"""
#!/usr/bin/python3
import os,sys,json
if '--version' in sys.argv:
 print('codex-cli 99.123.456'); sys.exit(0)
if '--help' in sys.argv:
 print('resume [SESSION_ID] --cd'); sys.exit(0)
if 'resume' not in sys.argv: sys.exit(3)
i=sys.argv.index('resume')
with open(os.environ['HISTORY_FIXTURE_RUNS'],'a') as f:
 f.write(json.dumps({'id':sys.argv[i+1],'cwd':os.getcwd(),'arguments':sys.argv[i:]})+'\n')
print('HISTORY FIXTURE READY',flush=True)
os.execv('/bin/cat',['cat'])
"""#
        let cli = root.appendingPathComponent("fixture-codex")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)

        func settleHistory() async throws {
            for _ in 0..<20 {
                guard let task = historyRefreshTask else { return }
                await task.value
                await Task.yield()
            }
            throw LaunchError.invalid("History fixture refresh did not settle.")
        }
        func search(_ text: String) async throws {
            historySearch.stringValue = text
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: historySearch))
            try await Task.sleep(for: .milliseconds(300))
            try await settleHistory()
        }
        func activate(_ id: String) throws {
            conversationSidebar.focusItem(id)
            guard conversationSidebar.focusedItemID == id, let responder = window.firstResponder,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
                throw LaunchError.invalid("History fixture could not focus the actual sidebar row: " + id)
            }
            responder.keyDown(with: event)
        }
        func receipts() throws -> [Substring] {
            let path = root.appendingPathComponent("resume-runs.jsonl")
            guard FileManager.default.fileExists(atPath: path.path) else { return [] }
            return try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
        }
        func cachedCount() async throws -> Int {
            var count = 0
            while true {
                let records = try await persistence.history(StoredHistoryQuery(allProjects: true, limit: 100, offset: count))
                count += records.count
                if records.count < 100 { return count }
            }
        }

        requestCatalogRefresh(force: true); try await settleHistory()
        let selected = store.state.selectedWorkspaceID, originalWorkspaceCount = store.state.workspaces.count
        let newestIdentity = ConversationID(provider: .codex, sessionID: "00000000-0000-4000-8000-000000000599")
        let beforeRegistration = try await persistence.conversation(newestIdentity)
        var projectID: UUID!, otherProjectID: UUID!
        store.update {
            projectID = $0.registerProject(WorkspaceLocation(path: checkout.path))
            otherProjectID = $0.registerProject(WorkspaceLocation(path: otherCheckout.path))
        }
        requestCatalogRefresh(force: true); try await settleHistory()
        window.contentView?.layoutSubtreeIfNeeded()
        var checks: [String: Bool] = [:]
        defer { try? PrivateFiles.write(checks, to: root.appendingPathComponent("history-checks.json")) }
        let initialCatalogCount = try await cachedCount()
        let afterRegistration = try await persistence.conversation(newestIdentity)
        checks["unbound_history_reassociates_without_duplicate_groups"] = beforeRegistration != nil && beforeRegistration?.projectID == nil &&
            afterRegistration?.projectID == otherProjectID && historyFixtureRecords(otherProjectID.uuidString).filter { $0.id == newestIdentity }.count == 1 &&
            !historyFixtureRecords("unbound").contains { $0.id == newestIdentity }
        checks["600_source_entries_use_lazy_metadata_catalog"] = initialCatalogCount > 0 && initialCatalogCount < 600 &&
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("history-legacy-refresh.json").path)
        checks["five_recent_rows_per_project"] = historyFixtureRecords(projectID.uuidString).count == 5 && historyFixtureRecords(otherProjectID.uuidString).count == 5
        checks["history_refresh_creates_no_workspace"] = store.state.workspaces.count == originalWorkspaceCount && store.state.workspaces.allSatisfy { $0.conversationID == nil }
        checks["refresh_preserves_selected_landing"] = store.state.selectedWorkspaceID == selected && store.state.selected?.isLanding == true
        checks["real_native_sidebar_rows_bounded"] = conversationSidebar.itemCount >= 12 && conversationSidebar.itemCount <= 18 &&
            conversationSidebar.visibleCellCount > 0 && conversationSidebar.visibleCellCount <= 24

        try activate("more:" + projectID.uuidString); try await settleHistory()
        checks["show_more_adds_ten_in_one_project"] = historyFixtureRecords(projectID.uuidString).count == 15 && historyFixtureRecords(otherProjectID.uuidString).count == 5
        try activate("more:" + projectID.uuidString); try await settleHistory()
        checks["show_more_repeats_without_expanding_other_project"] = historyFixtureRecords(projectID.uuidString).count == 25 && historyFixtureRecords(otherProjectID.uuidString).count == 5
        try activate("more:" + otherProjectID.uuidString); try await settleHistory()
        checks["second_project_has_independent_page_limit"] = historyFixtureRecords(projectID.uuidString).count == 25 && historyFixtureRecords(otherProjectID.uuidString).count == 15
        checks["larger_history_still_virtualizes_native_rows"] = conversationSidebar.itemCount >= 44 && conversationSidebar.itemCount <= 48 && conversationSidebar.visibleCellCount <= 32

        try activate("project:" + projectID.uuidString)
        checks["collapse_immediately_resets_only_its_history_page"] = historyFixtureRecords(projectID.uuidString).count == 5 &&
            historyFixtureRecords(otherProjectID.uuidString).count == 15 && store.state.selectedWorkspaceID == selected
        try await settleHistory()
        try activate("project:" + projectID.uuidString); try await settleHistory()
        checks["reexpanded_project_starts_with_five_again"] = historyFixtureRecords(projectID.uuidString).count == 5 &&
            historyFixtureRecords(otherProjectID.uuidString).count == 15
        try activate("more:" + projectID.uuidString); try await settleHistory()
        checks["show_more_after_reexpansion_adds_ten_without_skipping"] = historyFixtureRecords(projectID.uuidString).count == 15 &&
            historyFixtureRecords(projectID.uuidString).last?.metadata.title == "Conversation 0285"
        try activate("more:" + projectID.uuidString)
        try activate("project:" + projectID.uuidString)
        try activate("project:" + projectID.uuidString); try await settleHistory()
        checks["collapse_cancels_pending_expansion_without_restoring_large_page"] = historyFixtureRecords(projectID.uuidString).count == 5 &&
            historyFixtureRecords(otherProjectID.uuidString).count == 15 && store.state.selectedWorkspaceID == selected

        let oldestID = ConversationID(provider: .codex, sessionID: "00000000-0000-4000-8000-000000000000")
        let oldestBeforeSearch = try await persistence.conversation(oldestID)
        checks["oldest_search_result_was_not_cached"] = oldestBeforeSearch == nil
        try await search("Needle oldest")
        guard let original = historyFixtureRecords("search").first else { throw LaunchError.invalid("History fixture could not find uncached older metadata.") }
        let oldestAfterSearch = try await persistence.conversation(oldestID)
        checks["search_finds_oldest_outside_loaded_pages"] = historyFixtureRecords("search").count == 1 && original.id == oldestID && original.metadata.title == "Needle oldest conversation" && conversationSidebar.itemCount == 1
        checks["search_caches_only_requested_older_metadata"] = oldestAfterSearch?.id == oldestID
        let beforeOpen = try await launches.runtime.list()
        let beforeReceipts = try receipts()
        checks["startup_more_and_search_launch_zero_agents"] = beforeOpen.isEmpty && beforeReceipts.isEmpty && store.state.workspaces.count == originalWorkspaceCount
        var aliased = original; aliased.localAlias = "Local alias"
        try await persistence.saveHistory([aliased])
        store.update { $0.setProjectCollapsed(projectID, true) }
        try await search("")
        requestCatalogRefresh(force: true); try await settleHistory()
        let retainedAlias = try await persistence.conversation(original.id)
        checks["refresh_preserves_catalog_alias_and_collapsed_project"] = retainedAlias?.localAlias == "Local alias" && store.state.projects.first { $0.id == projectID }?.isCollapsed == true
        try await search("Local alias")
        checks["search_reveals_collapsed_project_without_expanding_it"] = conversationSidebar.itemCount == 1 &&
            historyFixtureRecords("search").first?.id == original.id && store.state.projects.first { $0.id == projectID }?.isCollapsed == true

        let rowID = "conversation:" + original.id.provider.rawValue + ":" + original.id.sessionID
        try activate(rowID); try activate(rowID)
        for _ in 0..<500 {
            if store.state.workspace(for: original.id)?.primaryTerminal?.binding != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let workspace = store.state.workspace(for: original.id), let primary = workspace.primaryTerminal,
              let binding = primary.binding else { throw LaunchError.invalid("History fixture did not resume its fake CLI.") }
        let targetID = workspace.id
        checks["opening_history_creates_one_workspace_lazily"] = store.state.workspaces.count == originalWorkspaceCount + 1 && store.state.workspaces.filter { $0.conversationID != nil }.count == 1
        checks["catalog_alias_promotes_to_open_workspace"] = workspace.title == "Local alias" && workspace.customTitle
        if let renderTask { await renderTask.value }
        let before = try await launches.runtime.inspect(binding)
        if let surface = surfaces.view(primary.id) { surface.insertText("HISTORY_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        store.update { $0.openSupport(.browser(url: "about:blank"), title: "Retained support", workspaceID: targetID); $0.hideWorkspace(targetID) }
        requestCatalogRefresh(force: true); try await settleHistory()
        checks["refresh_keeps_closed_view_binding_and_support"] = store.state.workspace(for: original.id)?.viewClosed == true && store.state.tab(primary.id)?.binding == binding && store.state.workspace(for: original.id)?.support?.tabs.count == 1
        openConversationWorkspace(targetID); openConversationWorkspace(targetID)
        try await Task.sleep(for: .milliseconds(250))
        if let renderTask { await renderTask.value }
        let after = try await launches.runtime.inspect(binding)
        let records = try receipts()
        guard let first = records.first, let receipt = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any] else {
            throw LaunchError.invalid("History fixture has no native resume receipt.")
        }
        checks["exact_id_cwd_no_prompt_one_execution"] = records.count == 1 && receipt["id"] as? String == original.id.sessionID &&
            receipt["arguments"] as? [String] == ["resume", original.id.sessionID, "--cd", original.metadata.directory]
        checks["resume_uses_capabilities_without_exact_version_lock"] = records.count == 1 && primary.launch?.executable == cli.path
        let actualDirectory = try FileManager.default.attributesOfItem(atPath: receipt["cwd"] as? String ?? "")
        let savedDirectory = try FileManager.default.attributesOfItem(atPath: original.metadata.directory)
        checks["actual_execution_cwd_matches_saved_folder"] = actualDirectory[.systemFileNumber] as? NSNumber == savedDirectory[.systemFileNumber] as? NSNumber && actualDirectory[.systemNumber] as? NSNumber == savedDirectory[.systemNumber] as? NSNumber
        checks["reopen_same_process_and_support"] = before?.processID == after?.processID && store.state.workspace(for: original.id)?.support?.tabs.count == 1
        checks["unsent_terminal_input_retained"] = surfaces.view(primary.id)?.visibleText().contains("HISTORY_UNSENT") == true
        var missing = original.metadata; missing.availability = .historyUnavailable
        store.update { $0.recordCatalogMetadata(missing, workspaceID: targetID, projectID: projectID); $0.hideWorkspace(targetID) }
        openConversationWorkspace(targetID)
        try await Task.sleep(for: .milliseconds(250))
        let retainedOwner = try await launches.runtime.inspect(binding)
        checks["owned_reconnect_does_not_require_saved_history"] = retainedOwner?.processID == before?.processID && store.state.tab(primary.id)?.binding == binding && store.state.workspace(for: original.id)?.viewClosed != true
        store.update { $0.recordCatalogMetadata(original.metadata, workspaceID: targetID, projectID: projectID) }
        try await launches.runtime.terminate(binding)
        await launches.reconcile(primary.id)
        openConversationWorkspace(targetID)
        for _ in 0..<500 {
            if let resumed = store.state.tab(primary.id)?.binding, resumed.id != binding.id, (try? receipts().count) == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let resumed = store.state.tab(primary.id)?.binding
        let endedRecords = try receipts()
        checks["explicit_ended_resume_starts_once_without_prompt"] = resumed != nil && resumed?.id != binding.id && endedRecords.count == 2 && store.state.tab(primary.id)?.promptDelivery == PromptDelivery.none
        var alive = 0
        for candidate in try await launches.runtime.list() {
            if let observation = try await launches.runtime.inspect(candidate), !observation.dead { alive += 1 }
        }
        checks["ended_resume_has_one_live_owned_process"] = alive == 1
        checks["retained_workspace_count_stays_bounded"] = store.state.workspaces.count <= originalWorkspaceCount + 1
        try store.state.validate(); checks["metadata_valid_v8"] = store.state.version == 8

        let watched = root.appendingPathComponent("history-watch-source")
        let watchedHistory = watched.appendingPathComponent("sessions/2026/10/18")
        try PrivateFiles.directory(watchedHistory)
        let watcher = HistorySourceWatcher()
        var watcherChanges = 0
        watcher.onChange = { watcherChanges += 1 }
        watcher.start(roots: [watched.path])
        try await Task.sleep(for: .milliseconds(1_100))
        watcherChanges = 0
        try Data("disposable shared-memory marker".utf8).write(to: watched.appendingPathComponent("state_99.sqlite-shm"))
        try await Task.sleep(for: .milliseconds(1_100))
        checks["watcher_ignores_database_shared_memory_noise"] = watcherChanges == 0
        try Data("{}\n".utf8).write(to: watchedHistory.appendingPathComponent("history.jsonl"))
        for _ in 0..<150 {
            if watcherChanges > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        checks["watcher_observes_nested_history_metadata"] = watcherChanges > 0
        watcher.stop()
        let stoppedCount = watcherChanges
        try Data("{}\n".utf8).write(to: watchedHistory.appendingPathComponent("after-stop.jsonl"))
        try await Task.sleep(for: .milliseconds(1_100))
        checks["stopped_watcher_does_not_refresh"] = watcherChanges == stoppedCount

        for (theme, size) in [(WorkspaceAppearance.dark, NSSize(width: 1120, height: 760)), (.light, NSSize(width: 680, height: 480))] {
            store.update { $0.appearance = theme }
            window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            if let content = window.contentView, let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: image)
                if let png = image.representation(using: .png, properties: [:]) { try png.write(to: root.appendingPathComponent("history-" + theme.rawValue + ".png")) }
            }
        }
        store.update { $0.appearance = .dark }; window.setContentSize(NSSize(width: 1120, height: 760))
        let finalCatalogCount = try await cachedCount()
        try PrivateFiles.write(["source_entries": 600, "initial_cached_entries": initialCatalogCount,
            "final_cached_entries": finalCatalogCount, "retained_workspaces": store.state.workspaces.count,
            "native_sidebar_items": conversationSidebar.itemCount, "visible_native_cells": conversationSidebar.visibleCellCount,
            "first_project_limit": 25, "second_project_limit": 15], to: root.appendingPathComponent("history-resources.json"))
        try PrivateFiles.write(checks, to: root.appendingPathComponent("history-checks.json"))
        guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("History native fixture failed: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", ")) }
    }
}

import AppKit
import SpookkyCore
import SpookkyWorkspace
import SpookkyRuntime

struct SyntheticHistoryCatalog: SessionCatalogReading {
    let root: URL
    func refresh(force: Bool) async -> SessionCatalogSnapshot {
        SessionCatalogSnapshot(conversations: (0..<600).map { index in
            ConversationMetadata(id: ConversationID(provider: .codex, sessionID: String(format: "00000000-0000-4000-8000-%012d", index)),
                title: index == 0 ? "Needle oldest conversation" : String(format: "Conversation %04d", index),
                directory: root.appendingPathComponent("history-checkout").path, updatedAt: Date(timeIntervalSince1970: Double(index)))
        })
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
        guard root.path.hasPrefix("/tmp/spookky-m1-"), ProcessInfo.processInfo.environment["SPOOKKY_M1_DATA"] != nil else { throw LaunchError.invalid("History fixture requires isolated state.") }
        let checkout = root.appendingPathComponent("history-checkout")
        try PrivateFiles.directory(checkout)
        let script = #"""
#!/usr/bin/python3
import os,sys,json
if '--version' in sys.argv:
 print('codex-cli 0.162.1'); sys.exit(0)
if '--help' in sys.argv:
 print('resume [SESSION_ID] --remote --cd'); sys.exit(0)
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
        await historyRefreshTask?.value
        let selected = store.state.selectedWorkspaceID
        var projectID: UUID!
        store.update { projectID = $0.registerProject(WorkspaceLocation(path: checkout.path)) }
        requestCatalogRefresh(force: true)
        await historyRefreshTask?.value
        var checks: [String: Bool] = [:]
        let saved = store.state.workspaces.filter { $0.conversationID != nil }
        checks["600_metadata_workspaces_no_launch"] = saved.count == 600 && saved.allSatisfy { $0.primaryTerminal?.launch == nil && $0.primaryTerminal?.binding == nil }
        checks["refresh_preserves_selection_and_closed_views"] = store.state.selectedWorkspaceID == selected && saved.allSatisfy { $0.viewClosed == true }
        checks["same_checkout_distinct_conversations"] = Set(saved.map(\.id)).count == 600 && Set(saved.map(\.directory)).count == 1
        checks["native_rows_bounded"] = workspaceRows.count <= 51 && historyMore.isHidden == false
        let retainedRows = workspaceRows
        historyMore.performClick(nil)
        checks["show_more_and_row_reuse"] = workspaceRows.count <= 101 && workspaceRows.count > 51 && retainedRows.allSatisfy { workspaceRows[$0.key] === $0.value }
        historySearch.stringValue = "Needle oldest"
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: historySearch))
        checks["search_includes_oldest_outside_page"] = workspaceRows.count == 1 && store.state.workspaces.first(where: { $0.id == workspaceRows.keys.first })?.catalogMetadata?.title == "Needle oldest conversation"
        let target = saved.first { $0.catalogMetadata?.title == "Needle oldest conversation" }!
        historySearch.stringValue = ""; historyLimit = 50; chromeRevision = ""; render()
        store.update { $0.renameWorkspace(target.id, "Local alias"); $0.setProjectCollapsed(projectID, true) }
        requestCatalogRefresh(force: true); await historyRefreshTask?.value
        checks["refresh_preserves_alias_and_collapsed_project"] = store.state.workspaces.first { $0.id == target.id }?.title == "Local alias" && store.state.projects.first { $0.id == projectID }?.isCollapsed == true
        historySearch.stringValue = "Needle oldest"
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: historySearch))
        checks["search_reveals_collapsed_project_without_mutating_it"] = workspaceRows[target.id] != nil && store.state.projects.first { $0.id == projectID }?.isCollapsed == true
        historySearch.stringValue = ""; chromeRevision = ""; render()
        openConversationWorkspace(target.id)
        for _ in 0..<200 {
            if store.state.workspaces.first(where: { $0.id == target.id })?.primaryTerminal?.binding != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let primary = store.state.workspaces.first(where: { $0.id == target.id })?.primaryTerminal,
              let binding = primary.binding else { throw LaunchError.invalid("History fixture did not resume its fake CLI.") }
        if let renderTask { await renderTask.value }
        let before = try await launches.runtime.inspect(binding)
        if let surface = surfaces.view(primary.id) { surface.insertText("HISTORY_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        store.update { $0.openSupport(.browser(url: "about:blank"), title: "Retained support", workspaceID: target.id); $0.hideWorkspace(target.id) }
        requestCatalogRefresh(force: true); await historyRefreshTask?.value
        checks["refresh_keeps_closed_view_and_binding"] = store.state.workspaces.first { $0.id == target.id }?.viewClosed == true && store.state.tab(primary.id)?.binding == binding
        openConversationWorkspace(target.id); openConversationWorkspace(target.id)
        try await Task.sleep(for: .milliseconds(250))
        if let renderTask { await renderTask.value }
        let after = try await launches.runtime.inspect(binding)
        let records = (try String(contentsOf: root.appendingPathComponent("resume-runs.jsonl"), encoding: .utf8)).split(separator: "\n")
        let receipt = try JSONSerialization.jsonObject(with: Data(records[0].utf8)) as! [String: Any]
        checks["exact_id_cwd_no_prompt_one_execution"] = records.count == 1 && receipt["id"] as? String == target.conversationID?.sessionID && receipt["arguments"] as? [String] == ["resume", target.conversationID!.sessionID, "--cd", target.catalogMetadata!.directory]
        let actualDirectory = try FileManager.default.attributesOfItem(atPath: receipt["cwd"] as? String ?? "")
        let savedDirectory = try FileManager.default.attributesOfItem(atPath: target.catalogMetadata!.directory)
        checks["actual_execution_cwd_matches_saved_folder"] = actualDirectory[.systemFileNumber] as? NSNumber == savedDirectory[.systemFileNumber] as? NSNumber && actualDirectory[.systemNumber] as? NSNumber == savedDirectory[.systemNumber] as? NSNumber
        checks["reopen_same_process_and_support"] = before?.processID == after?.processID && store.state.workspaces.first { $0.id == target.id }?.support?.tabs.count == 1
        checks["unsent_terminal_input_retained"] = surfaces.view(primary.id)?.visibleText().contains("HISTORY_UNSENT") == true
        var missing = target.catalogMetadata!; missing.availability = .historyUnavailable
        store.update { $0.recordCatalogMetadata(missing, workspaceID: target.id, projectID: nil); $0.hideWorkspace(target.id) }
        openConversationWorkspace(target.id)
        try await Task.sleep(for: .milliseconds(250))
        let retainedOwner = try await launches.runtime.inspect(binding)
        checks["owned_reconnect_does_not_require_saved_history"] = retainedOwner?.processID == before?.processID && store.state.tab(primary.id)?.binding == binding && store.state.workspaces.first { $0.id == target.id }?.viewClosed != true
        store.update { $0.recordCatalogMetadata(target.catalogMetadata!, workspaceID: target.id, projectID: nil) }
        try await launches.runtime.terminate(binding)
        await launches.reconcile(primary.id)
        openConversationWorkspace(target.id)
        for _ in 0..<200 {
            if let resumed = store.state.tab(primary.id)?.binding, resumed.id != binding.id,
               let bytes = try? String(contentsOf: root.appendingPathComponent("resume-runs.jsonl"), encoding: .utf8),
               bytes.split(separator: "\n").count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let resumed = store.state.tab(primary.id)?.binding
        let endedRecords = (try String(contentsOf: root.appendingPathComponent("resume-runs.jsonl"), encoding: .utf8)).split(separator: "\n")
        checks["explicit_ended_resume_starts_once_without_prompt"] = resumed != nil && resumed?.id != binding.id && endedRecords.count == 2 && store.state.tab(primary.id)?.promptDelivery == PromptDelivery.none
        var alive = 0
        for candidate in try await launches.runtime.list() {
            if let observation = try await launches.runtime.inspect(candidate), !observation.dead { alive += 1 }
        }
        checks["ended_resume_has_one_live_owned_process"] = alive == 1
        try store.state.validate()
        checks["metadata_valid"] = true
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
        try PrivateFiles.write(["catalog_entries": 600, "final_native_workspace_rows": workspaceRows.count, "page_limit": historyLimit], to: root.appendingPathComponent("history-resources.json"))
        try PrivateFiles.write(checks, to: root.appendingPathComponent("history-checks.json"))
        guard checks.values.allSatisfy({ $0 }) else { throw LaunchError.invalid("History native fixture failed: " + checks.filter { !$0.value }.keys.sorted().joined(separator: ", ")) }
    }
}

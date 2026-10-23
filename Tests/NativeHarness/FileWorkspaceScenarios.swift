import AppKit
import SpookkyCore
import SpookkyFiles
import SpookkyGit
import SpookkyWorkspace
import SpookkySyntax

extension FileWorkspaceController {
    func settleForFixture() async {
        for _ in 0..<32 {
            let loading = generation, previewing = previewGeneration
            if let loadTask { await loadTask.value }
            if let previewTask { await previewTask.value }
            if loading == generation && previewing == previewGeneration { break }
        }
        layout.layoutSubtreeIfNeeded()
    }
    func previewForFixture(path: String, group: String?, split: Bool = false, waitForSyntax: Bool = true) async throws -> Double {
        guard ApplicationArguments.values.contains("--workspace-benchmark-files") else { throw ChangesError.unsupported("File measurements require a disposable benchmark.") }
        let started = ProcessInfo.processInfo.systemUptime
        edit { $0.selectedPath = path; $0.selectedGroup = group; $0.preview = true; $0.splitDiff = split }
        await settleForFixture()
        openSelection(); await settleForFixture()
        let layoutStarted = ProcessInfo.processInfo.systemUptime
        layout.layoutSubtreeIfNeeded(); preview.layoutSubtreeIfNeeded()
        previewTimings["layout_ms"] = (ProcessInfo.processInfo.systemUptime - layoutStarted) * 1000
        guard !diff.isEmpty else {
            throw ChangesError.unsupported(previewNotice.stringValue + " Fixture: changes=\(state.changes), files=\(snapshot?.files.count ?? -1), group=\(state.selectedGroup ?? "none").")
        }
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        previewTimings["total_ms"] = elapsed
        if !waitForSyntax { return elapsed }
        await settleSyntaxForFixture()
        previewTimings["syntax_ready_ms"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
        previewTimings["syntax_colored"] = (oldSyntax != nil || newSyntax != nil) ? 1 : 0
        return elapsed
    }
    func settleSyntaxForFixture() async {
        guard ApplicationArguments.values.contains("--workspace-benchmark-files") else { return }
        if let syntaxTask { await syntaxTask.value }
        preview.layoutSubtreeIfNeeded()
    }
    func previewMatchesForFixture(path: String, text: String) -> Bool {
        guard ApplicationArguments.values.contains("--workspace-benchmark-count") else { return false }
        return title.stringValue == path && diff.contains { $0.text.contains(text) } &&
            diffTable.numberOfRows == displayRows.count && !displayRows.isEmpty
    }
    func columnGeometryMatchesForFixture() -> Bool {
        diffTable.layoutSubtreeIfNeeded()
        let visible = diffTable.rows(in: diffScroll.contentView.documentVisibleRect)
        guard visible.length > 0 else { return false }
        for (index, column) in diffTable.tableColumns.enumerated() {
            guard abs(diffTable.rect(ofColumn: index).width - column.width) < 0.5 else { return false }
            for row in visible.location..<min(NSMaxRange(visible), displayRows.count) {
                guard let cell = diffTable.view(atColumn: index, row: row, makeIfNecessary: true) as? DiffCell,
                      abs(cell.bounds.width - column.width) < 0.5 else { return false }
                cell.layoutSubtreeIfNeeded()
                if ["text", "before", "after"].contains(column.identifier.rawValue),
                   cell.label.bounds.width < column.width - 8 { return false }
            }
        }
        return true
    }
    func interactionChecksForFixture() async throws -> [String: Bool] {
        guard ApplicationArguments.values.contains("--workspace-benchmark-files") else { throw ChangesError.unsupported("Disposable file fixture required.") }
        let wasMaximized = state.maximized
        edit { $0.maximized = true }
        await settleForFixture()
        var unifiedTransition = true, splitTransition = true
        for split in [false, true] {
            for (path, group) in [("sample.swift", "Unstaged"), ("added.swift", "Untracked"), ("sample.swift", "Unstaged")] {
                _ = try await previewForFixture(path: path, group: group, split: split)
                let valid = columnGeometryMatchesForFixture() && selectedFile?.group.rawValue == group
                    && (group == "Untracked" || splitRendered == split)
                if split { splitTransition = splitTransition && valid }
                else { unifiedTransition = unifiedTransition && valid }
            }
        }
        edit { $0.maximized = wasMaximized; $0.splitDiff = false }
        await settleForFixture()
        for index in 0..<12 {
            edit { $0.selectedPath = index % 2 == 0 ? "sample.swift" : "other.swift"; $0.selectedGroup = "Unstaged" }
            openSelection(); try await Task.sleep(for: .milliseconds(5))
        }
        if let previewTask { await previewTask.value }
        let lastSelection = state.selectedPath == "other.swift" && diff.contains { $0.kind == .addition && $0.text.contains(String(repeating: "z", count: 40)) }
        diffTable.selectRowIndexes(IndexSet(integersIn: 0..<min(4, displayRows.count)), byExtendingSelection: false)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let copied = diffTable.copySelection(to: pasteboard) && pasteboard.string(forType: .string) == diffTable.copyText?()
        let selectedRows = diffTable.selectedRowIndexes, selectedText = diffTable.copyText?()
        let contentFrame = diffScroll.frame, contentCount = diff.count
        let informationVisible = !informationButton.isHidden
        let sidebarStatus = status.stringValue, sidebarStatusHidden = status.isHidden
        refresh(); openSelection(); preview.layoutSubtreeIfNeeded(); sidebar.layoutSubtreeIfNeeded()
        let quietPreview = previewNotice.isHidden && diff.count == contentCount && diffScroll.frame == contentFrame
        let informationStable = (!informationButton.isHidden) == informationVisible
        await settleForFixture()
        let quietSidebar = status.stringValue == sidebarStatus && status.isHidden == sidebarStatusHidden
        let selectionSurvivedRefresh = diffTable.selectedRowIndexes == selectedRows && diffTable.copyText?() == selectedText
        guard let workspaceID, let changesTabID = store.state.selected?.support?.selectedTabID,
              let selectedPath = state.selectedPath else { throw ChangesError.unsupported("Changes fixture selection is missing.") }
        store.update { $0.openSupport(.file(path: selectedPath), title: (selectedPath as NSString).lastPathComponent, workspaceID: workspaceID) }
        await settleForFixture()
        let rawFile = !state.changes && !state.sidebar && selectedFile == nil && !diff.contains { $0.kind == .addition || $0.kind == .removal }
        store.update { $0.selectSupport(changesTabID, workspaceID: workspaceID) }
        await settleForFixture()
        let restoredComparison = state.changes && state.sidebar && selectedFile?.group == .unstaged && diff.contains { $0.kind == .addition }
        let live = URL(fileURLWithPath: root).appendingPathComponent("live.txt")
        try Data("event 0".utf8).write(to: live)
        store.update { $0.openSupport(.file(path: "live.txt"), title: "live.txt", workspaceID: workspaceID) }
        refresh(); await settleForFixture()
        layout.window?.makeFirstResponder(diffTable)
        let writer = Task.detached {
            for index in 1...40 {
                try Data("event \(index)".utf8).write(to: live)
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await writer.value
        for _ in 0..<150 {
            if diff.contains(where: { $0.text == "event 40" }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let refreshed = diff.contains { $0.text == "event 40" }
        let focused = layout.window?.firstResponder === diffTable
        try FileManager.default.removeItem(at: live)
        refresh(); await settleForFixture()
        let unavailableVisible = !previewNotice.isHidden && !previewNotice.stringValue.isEmpty
        let unavailableText = previewNotice.stringValue
        refresh(); openSelection()
        let errorSurvivedRefresh = !previewNotice.isHidden && previewNotice.stringValue == unavailableText
        await settleForFixture()
        edit { $0.preview = false; $0.sidebar = false }
        if layout.supportingOnly { store.update { $0.setSupportingLayout(.collapsed, workspaceID: workspaceID) } }
        return ["modified_added_modified_geometry": unifiedTransition, "split_added_split_geometry": splitTransition,
                "latest_selection_wins": lastSelection, "selected_rows_copy": copied, "preview_selection_survived_refresh": selectionSurvivedRefresh,
                "sidebar_refresh_quiet": quietSidebar, "preview_refresh_geometry_stable": quietPreview,
                "preview_information_control_stable": informationStable, "unavailable_preview_notice_visible": unavailableVisible,
                "error_notice_survived_refresh": errorSurvivedRefresh,
                "files_changes_tab_context_isolation": rawFile && restoredComparison,
                "continuous_edits_refreshed": refreshed, "refresh_preserved_focus": focused,
                "hidden_watcher_stopped": diagnostics["watchers"] == 0]
    }
}

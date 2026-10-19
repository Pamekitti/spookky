import Foundation

extension WorkspaceState {
    /// A provider can switch saved conversations while retaining the same terminal process.
    mutating func moveObservedConversation(tab: WorkspaceTab, event: AgentEvent, followTerminal: Bool) -> Bool {
        guard let sessionID = event.sessionID, !sessionID.isEmpty,
              let source = workspaces.firstIndex(where: { $0.primaryTerminalID == tab.id }),
              let oldID = workspaces[source].conversationID else { return false }
        let id = ConversationID(provider: event.provider, sessionID: sessionID)
        guard id != oldID else { return false }
        let original = workspaces[source]
        let matches = workspaces.indices.filter { workspaces[$0].conversationID == id }
        let reusable = matches.count == 1 ? matches.first.flatMap { index -> Int? in
            let candidate = workspaces[index]
            guard let primary = candidate.primaryTerminal, primary.binding == nil, primary.launch == nil,
                  primary.isEditable || primary.status == .ended,
                  candidate.locationOwnerWorkspaceID == nil,
                  candidate.anchor != nil || candidate.locationDraft?.mode != .worktree,
                  candidate.locationOperationID.map({ operationID in locations?.operations.first { $0.id == operationID }?.status == .complete }) ?? true,
                  candidate.directory == original.directory else { return nil }
            return index
        } : nil

        // The old conversation retains its own draft and display state, but no live receipt.
        var saved = WorkspaceTab(tool: oldID.provider)
        saved.title = tab.title; saved.customTitle = tab.customTitle; saved.draft = tab.draft
        saved.status = .ended; saved.startDirectory = tab.startDirectory
        saved.providerTitle = tab.providerTitle; saved.activity = tab.activity; saved.activity?.disconnect()
        guard let slot = workspaces[source].tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        workspaces[source].tabs[slot] = saved
        workspaces[source].primaryTerminalID = saved.id
        if workspaces[source].selectedTabID == tab.id { workspaces[source].selectedTabID = saved.id }
        if workspaces[source].catalogMetadata == nil {
            workspaces[source].catalogMetadata = ConversationMetadata(id: oldID, title: tab.providerTitle?.title,
                directory: tab.startDirectory ?? tab.binding?.directory ?? original.directory,
                updatedAt: Date(timeIntervalSince1970: event.occurredAt), availability: .historyUnavailable)
        }

        let destination: Int
        if let reusable { destination = reusable }
        else {
            var sibling = Workspace(location: original.anchor ?? original.selectedLocation, projectID: original.projectID,
                                    tool: id.provider, title: id.provider.displayName + " " + String(id.sessionID.prefix(8)))
            sibling.anchor = original.anchor; sibling.conversationID = id; sibling.viewClosed = !followTerminal
            workspaces.append(sibling); destination = workspaces.count - 1
        }
        let placeholder = workspaces[destination].primaryTerminal!
        var live = tab
        live.title = placeholder.title; live.customTitle = placeholder.customTitle; live.draft = placeholder.draft
        if !live.draft.isEmpty { live.draft = TerminalDraft(tool: id.provider) }
        live.providerTitle = placeholder.providerTitle; live.projectAssociation = nil
        var activity = AgentActivity(invocationID: event.invocationID, provider: event.provider)
        activity.manualUnread = placeholder.activity?.unread ?? false
        guard activity.apply(event) else { return false }
        live.activity = activity
        let preserveDraft = reusable != nil && !placeholder.draft.isEmpty
        if !preserveDraft { workspaces[destination].tabs.removeAll { $0.id == placeholder.id } }
        workspaces[destination].tabs.append(live)
        workspaces[destination].primaryTerminalID = live.id
        if workspaces[destination].selectedTabID == placeholder.id { workspaces[destination].selectedTabID = live.id }
        if workspaces[destination].anchor == nil {
            workspaces[destination].anchor = original.anchor ?? original.selectedLocation
        }
        associateConversation(id, workspaceID: workspaces[destination].id)
        if preserveDraft { _ = separateAgentTerminal(placeholder.id, select: false) }
        if followTerminal {
            workspaces[destination].viewClosed = false
            selectedWorkspaceID = workspaces[destination].id
            selectPrimaryContent(workspaceID: workspaces[destination].id)
        }
        return true
    }
}

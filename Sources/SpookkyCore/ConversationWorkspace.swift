import Foundation

public enum FullWidthSelection: Codable, Equatable, Sendable {
    case primary
    case support(UUID)
}
public enum SupportingLayout: String, Codable, Sendable { case collapsed, split, fullWidth }
public enum SupportingTarget: Codable, Equatable, Sendable {
    case changes
    case startPage
    case file(path: String)
    case browser(url: String)
    case artifact(path: String)
    case terminal(tabID: UUID)
}
public struct SupportingTab: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var target: SupportingTarget
    public var title: String
    public var fileView: FileViewState?
    public init(id: UUID = UUID(), target: SupportingTarget, title: String, fileView: FileViewState? = nil) {
        self.id = id; self.target = target; self.title = String(title.prefix(256)); self.fileView = fileView
    }
}
public struct SupportingPanelState: Codable, Equatable, Sendable {
    public var tabs: [SupportingTab] = []
    public var selectedTabID: UUID?
    public var layout: SupportingLayout = .collapsed
    public var fraction: Double = 0.5
    public var fullWidthSelection: FullWidthSelection?
    public init() {}
    public var selected: SupportingTab? { tabs.first { $0.id == selectedTabID } }
    public var resolvedFullWidthSelection: FullWidthSelection {
        fullWidthSelection ?? selected.map { .support($0.id) } ?? .primary
    }
}

extension Workspace {
    public var retainedSupportingTerminals: [WorkspaceTab] {
        tabs.filter { terminal in terminal.id != primaryTerminalID &&
            !(support?.tabs.contains { if case .terminal(let id) = $0.target { return id == terminal.id }; return false } ?? false)
        }
    }
    public var isValidConversationWorkspace: Bool {
        guard let primaryTerminalID, tabs.contains(where: { $0.id == primaryTerminalID }), let support,
              support.fraction.isFinite, (0.2...0.8).contains(support.fraction),
              Set(support.tabs.map(\.id)).count == support.tabs.count,
              support.selectedTabID == nil || support.tabs.contains(where: { $0.id == support.selectedTabID }) else { return false }
        if case .support(let id) = support.fullWidthSelection,
           !support.tabs.contains(where: { $0.id == id }) { return false }
        if let conversationID {
            guard conversationID.provider != .shell, !conversationID.sessionID.isEmpty,
                  conversationID.sessionID.utf8.count <= 256, !conversationID.sessionID.contains("\0") else { return false }
        }
        return support.tabs.allSatisfy { tab in
            guard tab.title.utf8.count <= 1_024, tab.fileView?.isValid != false else { return false }
            switch tab.target {
            case .terminal(let id): return id != primaryTerminalID && tabs.contains { $0.id == id }
            case .file(let path), .artifact(let path): return !path.isEmpty && !path.contains("\0") && path.utf8.count <= 16_384
            case .browser(let url): return !url.contains("\0") && url.utf8.count <= 16_384
            case .changes, .startPage: return true
            }
        }
    }
}

extension WorkspaceState {
    public var primaryTerminalID: UUID? { selected?.primaryTerminalID }
    public var openWorkspaces: [Workspace] { workspaces.filter { !$0.isLanding && $0.viewClosed != true && (version < 8 || !isArchived($0)) } }
    public func workspace(for id: ConversationID) -> Workspace? {
        preferredWorkspace(in: workspaces.filter { $0.conversationID == id })
    }
    public func preferredWorkspace(in matches: [Workspace]) -> Workspace? {
        return matches.first { $0.primaryTerminal?.status == .running } ??
            matches.first { $0.id == selectedWorkspaceID } ?? matches.first
    }

    @discardableResult public mutating func ensureConversationWorkspace(_ id: ConversationID, location: WorkspaceLocation,
                                                                      projectID: UUID? = nil, select: Bool = true) -> UUID {
        if let existing = workspace(for: id) {
            if select { selectWorkspace(existing.id) }
            return existing.id
        }
        let title = select ? WorkspaceNaming.friendly(excluding: workspaces.map(\.title))
            : id.provider.displayName + " " + String(id.sessionID.prefix(8))
        var workspace = Workspace(location: location, projectID: projectID, tool: id.provider, title: title)
        workspace.viewClosed = !select
        workspaces.append(workspace)
        associateConversation(id, workspaceID: workspace.id)
        if select { selectWorkspace(workspace.id) }
        return workspace.id
    }
    public mutating func associateConversation(_ id: ConversationID, workspaceID: UUID) {
        guard id.provider != .shell, !id.sessionID.isEmpty, id.sessionID.utf8.count <= 256, !id.sessionID.contains("\0"),
              let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].conversationID == nil || workspaces[index].conversationID == id else { return }
        let previousKey = workspaces[index].threadKey
        workspaces[index].conversationID = id
        if previousKey != id.threadKey, let previous = threadPresentations?.removeValue(forKey: previousKey) {
            var shared = presentation(for: id.threadKey)
            shared.pinnedAt = shared.pinnedAt ?? previous.pinnedAt
            shared.archivedAt = shared.archivedAt ?? previous.archivedAt
            shared.lastVisitedAt = max(shared.lastVisitedAt ?? .distantPast, previous.lastVisitedAt ?? .distantPast)
            if !shared.hasProjectOverride, previous.hasProjectOverride {
                shared.hasProjectOverride = true; shared.projectOverride = previous.projectOverride
            }
            threadPresentations?[id.threadKey] = shared
        }
        let placeholders = Set(workspaces.filter { candidate in
            candidate.id != workspaceID && candidate.conversationID == id && candidate.catalogMetadata != nil &&
                !candidate.customTitle && candidate.anchor == nil && candidate.locationOperationID == nil &&
                candidate.locationOwnerWorkspaceID == nil && candidate.support?.tabs.isEmpty != false &&
                candidate.tabs.allSatisfy { $0.isEditable && $0.binding == nil && $0.launch == nil &&
                    $0.draft.prompt.isEmpty && !$0.customTitle }
        }.map(\.id))
        workspaces.removeAll { placeholders.contains($0.id) }
        if let selectedWorkspaceID, placeholders.contains(selectedWorkspaceID) { self.selectedWorkspaceID = workspaceID }
        let matches = workspaces.indices.filter { workspaces[$0].conversationID == id }
        for index in matches { workspaces[index].conversationOwnershipAmbiguous = matches.count > 1 }
    }
    public mutating func setProviderTitle(_ title: String?, conversationID: ConversationID) {
        updateConversationTitle(provider: conversationID.provider, sessionID: conversationID.sessionID, title: title)
    }
    public mutating func hideWorkspace(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].viewClosed = true
        if selectedWorkspaceID == id {
            selectedWorkspaceID = version >= 7
                ? openWorkspaces.max { ($0.lastViewedAt ?? .distantPast) < ($1.lastViewedAt ?? .distantPast) }?.id
                : openWorkspaces.last?.id
            if version >= 7, selectedWorkspaceID == nil {
                showLanding(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            }
        }
    }
    @discardableResult public mutating func openSupport(_ target: SupportingTarget, title: String, workspaceID: UUID? = nil,
                                                      fileView: FileViewState? = nil) -> UUID? {
        guard let index = workspaces.firstIndex(where: { $0.id == (workspaceID ?? selectedWorkspaceID) }) else { return nil }
        var context = fileView
        if case .file(let path) = target {
            var view = context ?? FileViewState()
            view.selectedPath = path; view.preview = true; view.sidebar = false
            view.changes = false; view.selectedGroup = nil; view.againstBranch = false; view.reference = nil
            context = view
        }
        if context?.changes == false { context?.selectedGroup = nil; context?.againstBranch = false; context?.reference = nil }
        guard context?.isValid != false else { return nil }
        var panel = workspaces[index].support ?? SupportingPanelState()
        // Browser tabs may share a URL while retaining separate form state.
        let existing = panel.tabs.first { tab in
            if case .browser = target { return false }
            if case .startPage = target { return false }
            return tab.target == target
        }
        let id = existing?.id ?? UUID()
        if existing == nil { panel.tabs.append(SupportingTab(id: id, target: target, title: title, fileView: context)) }
        else if let context, let slot = panel.tabs.firstIndex(where: { $0.id == id }) { panel.tabs[slot].fileView = context }
        workspaces[index].support = panel
        selectSupport(id, workspaceID: workspaces[index].id)
        return id
    }
    public mutating func setSupportingFileView(_ view: FileViewState, workspaceID: UUID) {
        guard view.isValid, let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              let selected = workspaces[index].support?.selectedTabID,
              let slot = workspaces[index].support?.tabs.firstIndex(where: { $0.id == selected }) else { return }
        switch workspaces[index].support?.tabs[slot].target {
        case .file(let path): guard path == view.selectedPath else { return }
        case .changes: break
        default: return
        }
        workspaces[index].support?.tabs[slot].fileView = view
    }
    public mutating func selectPrimaryContent(workspaceID: UUID? = nil) {
        guard let index = workspaces.firstIndex(where: { $0.id == (workspaceID ?? selectedWorkspaceID) }),
              let primary = workspaces[index].primaryTerminalID else { return }
        workspaces[index].selectedTabID = primary
        if workspaces[index].support == nil { workspaces[index].support = SupportingPanelState() }
        workspaces[index].support?.fullWidthSelection = .primary
    }
    public mutating func selectSupport(_ id: UUID, workspaceID: UUID? = nil) {
        guard let index = workspaces.firstIndex(where: { $0.id == (workspaceID ?? selectedWorkspaceID) }),
              workspaces[index].support?.tabs.contains(where: { $0.id == id }) == true else { return }
        workspaces[index].support?.selectedTabID = id
        workspaces[index].support?.fullWidthSelection = .support(id)
        if workspaces[index].support?.layout == .collapsed { workspaces[index].support?.layout = .split }
        if case .terminal(let terminalID) = workspaces[index].support?.selected?.target { workspaces[index].selectedTabID = terminalID }
    }
    public mutating func updateSupport(_ id: UUID, target: SupportingTarget, title: String? = nil, workspaceID: UUID? = nil) {
        guard let index = workspaces.firstIndex(where: { $0.id == (workspaceID ?? selectedWorkspaceID) }),
              let tab = workspaces[index].support?.tabs.firstIndex(where: { $0.id == id }) else { return }
        if workspaces[index].support?.tabs[tab].target != target {
            if case .file(let path) = target {
                var view = FileViewState(); view.selectedPath = path; view.preview = true; view.sidebar = false
                workspaces[index].support?.tabs[tab].fileView = view
            } else if case .changes = target { workspaces[index].support?.tabs[tab].fileView = nil }
        }
        workspaces[index].support?.tabs[tab].target = target
        if let title { workspaces[index].support?.tabs[tab].title = String(title.prefix(256)) }
    }
    public mutating func closeSupport(_ id: UUID, workspaceID: UUID? = nil) {
        guard let index = workspaces.firstIndex(where: { $0.id == (workspaceID ?? selectedWorkspaceID) }),
              var panel = workspaces[index].support, let slot = panel.tabs.firstIndex(where: { $0.id == id }) else { return }
        let displayed = panel.resolvedFullWidthSelection
        let replacesSelection = panel.selectedTabID == id || displayed == .support(id)
        panel.tabs.remove(at: slot)
        if replacesSelection {
            panel.selectedTabID = panel.tabs.isEmpty ? nil : panel.tabs[max(0, slot - 1)].id
        }
        if panel.tabs.isEmpty {
            panel.layout = .collapsed; panel.fullWidthSelection = .primary
        } else if displayed == .support(id) {
            panel.fullWidthSelection = panel.selectedTabID.map { .support($0) } ?? .primary
        }
        workspaces[index].support = panel
        if panel.tabs.isEmpty || displayed == .primary {
            if let primary = workspaces[index].primaryTerminalID { workspaces[index].selectedTabID = primary }
        } else if replacesSelection {
            if case .terminal(let terminalID) = panel.selected?.target { workspaces[index].selectedTabID = terminalID }
            else if let primary = workspaces[index].primaryTerminalID { workspaces[index].selectedTabID = primary }
        }
    }
    public mutating func setSupportingLayout(_ layout: SupportingLayout, fraction: Double? = nil, workspaceID: UUID? = nil) {
        guard let index = workspaces.firstIndex(where: { $0.id == (workspaceID ?? selectedWorkspaceID) }) else { return }
        if workspaces[index].support == nil { workspaces[index].support = SupportingPanelState() }
        if layout == .fullWidth, workspaces[index].support?.layout != .fullWidth {
            let workspaceID = workspaces[index].id
            if let selected = workspaces[index].support?.selectedTabID { selectSupport(selected, workspaceID: workspaceID) }
            else { selectPrimaryContent(workspaceID: workspaceID) }
        }
        workspaces[index].support?.layout = layout
        if let fraction, fraction.isFinite { workspaces[index].support?.fraction = min(0.8, max(0.2, fraction)) }
    }

    @discardableResult public mutating func separateAgentTerminal(_ tabID: UUID, select: Bool = true) -> UUID? {
        guard let index = workspaces.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
              workspaces[index].primaryTerminalID != tabID,
              let tab = workspaces[index].tabs.first(where: { $0.id == tabID }) else { return workspace(containing: tabID)?.id }
        let original = workspaces[index]
        var sibling = Workspace(location: original.anchor ?? original.selectedLocation, projectID: original.projectID,
                                tool: tab.draft.tool, title: WorkspaceNaming.friendly(excluding: workspaces.map(\.title)))
        sibling.anchor = original.anchor; sibling.tabs = [tab]; sibling.selectedTabID = tabID; sibling.primaryTerminalID = tabID
        let supports = workspaces[index].support?.tabs.filter {
            if case .terminal(let id) = $0.target { return id == tabID }; return false
        }.map(\.id) ?? []
        for id in supports { closeSupport(id, workspaceID: original.id) }
        workspaces[index].tabs.removeAll { $0.id == tabID }
        if workspaces[index].selectedTabID == tabID { workspaces[index].selectedTabID = original.primaryTerminalID! }
        workspaces.append(sibling)
        if select { selectedWorkspaceID = sibling.id }
        return sibling.id
    }

    @discardableResult public mutating func resolveConversationLocation(workspaceID: UUID) -> Bool {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return false }
        guard let ownerID = workspaces[index].locationOwnerWorkspaceID else { return true }
        guard let owner = workspaces.first(where: { $0.id == ownerID }),
              let operationID = owner.locationOperationID,
              let operation = locations?.operations.first(where: { $0.id == operationID }),
              operation.status == .complete, let location = owner.anchor ?? operation.location else { return false }
        workspaces[index].selectedLocation = location
        workspaces[index].locationDraft = nil; workspaces[index].locationOwnerWorkspaceID = nil
        return true
    }

    /// Splits metadata only. No launch, inspection, prompt delivery, or process termination occurs here.
    public mutating func migrateConversationWorkspaces() {
        guard version == 5 else { return }
        var result: [Workspace] = []
        for original in workspaces {
            let agents = original.tabs.filter { ($0.binding?.tool ?? $0.launch?.tool ?? $0.draft.tool) != .shell || ($0.activity?.sessionID != nil && $0.activity?.provider != .shell) }
            let primary = agents.first(where: { $0.id == original.selectedTabID }) ?? agents.first ?? original.tabs.first(where: { $0.id == original.selectedTabID }) ?? original.tabs[0]
            var retained = original
            retained.primaryTerminalID = primary.id; retained.split = nil; retained.viewClosed = false
            retained.tabs = original.tabs.filter { $0.id == primary.id || !agents.contains($0) }
            retained.selectedTabID = primary.id
            retained.support = migrationPanel(original, terminals: retained.tabs.filter { $0.id != primary.id })
            if let activity = primary.activity, let sessionID = activity.sessionID, !sessionID.isEmpty, !sessionID.contains("\0"), activity.provider != .shell {
                retained.conversationID = ConversationID(provider: activity.provider, sessionID: sessionID)
            }
            result.append(retained)
            for agent in agents where agent.id != primary.id {
                var sibling = Workspace(location: original.selectedLocation, projectID: original.projectID,
                                        tool: agent.draft.tool, title: original.title)
                sibling.anchor = original.anchor; sibling.customTitle = original.customTitle; sibling.automaticTitle = original.automaticTitle
                sibling.tabs = [agent]; sibling.selectedTabID = agent.id; sibling.primaryTerminalID = agent.id
                sibling.locationDraft = original.locationDraft
                if original.locationOperationID != nil && original.anchor == nil { sibling.locationOwnerWorkspaceID = original.id }
                if let activity = agent.activity, let sessionID = activity.sessionID, !sessionID.isEmpty, !sessionID.contains("\0"), activity.provider != .shell {
                    sibling.conversationID = ConversationID(provider: activity.provider, sessionID: sessionID)
                }
                result.append(sibling)
            }
        }
        let counts = Dictionary(grouping: result.compactMap(\.conversationID), by: { $0 }).mapValues(\.count)
        for index in result.indices {
            if let id = result[index].conversationID, counts[id, default: 0] > 1 { result[index].conversationOwnershipAmbiguous = true }
        }
        workspaces = result; version = 6
    }
    private func migrationPanel(_ original: Workspace, terminals: [WorkspaceTab]) -> SupportingPanelState {
        var panel = SupportingPanelState()
        panel.tabs = terminals.map { SupportingTab(id: $0.id, target: .terminal(tabID: $0.id), title: $0.title) }
        if let file = original.fileView, file.sidebar || file.preview {
            let target: SupportingTarget = file.selectedPath.map { .file(path: $0) } ?? .changes
            let tab = SupportingTab(target: target, title: file.selectedPath ?? "Changes", fileView: file)
            panel.tabs.append(tab); panel.selectedTabID = tab.id; panel.layout = file.maximized ? .fullWidth : .split
            panel.fraction = file.fraction
        } else if terminals.contains(where: { $0.id == original.selectedTabID }) || original.split != nil {
            panel.selectedTabID = terminals.first(where: { $0.id == original.selectedTabID })?.id ?? terminals.first?.id
            if panel.selectedTabID != nil { panel.layout = .split }
        }
        return panel
    }
}

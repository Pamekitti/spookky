import Foundation

public enum TabStatus: String, Codable, Sendable {
    case draft, preparing, launching, running, reconnecting, ended, failed, uncertain, unavailable
}

public enum FailurePhase: String, Codable, Sendable { case validation, launch, attachment, observation, termination }
public enum PromptDelivery: String, Codable, Sendable { case none, pending, suppliedToProcess, uncertain }
public enum WorkspaceAppearance: String, Codable, Sendable { case system, dark, light }
public enum FailureRecovery: String, Codable, Sendable { case locateFolder }
public enum WorkspaceTransition: Sendable {
    case preparing
    case intent(LaunchSpec, PromptDelivery)
    case observed(SessionBinding, dead: Bool, exitCode: Int?, prompt: PromptDelivery?)
    case failure(TabStatus, TabFailure, clearIntent: Bool)
    case terminated
}

public struct TerminalDraft: Codable, Equatable, Sendable {
    public var tool: SessionTool
    public var prompt: String
    private var fullAccessChoice: Bool?
    public var fullAccess: Bool {
        get { fullAccessChoice == true }
        set { fullAccessChoice = newValue ? true : nil }
    }
    private var modelChoices: [String: AgentModelSelection]?
    public func recordedModelSelection(for tool: SessionTool) -> AgentModelSelection? { modelChoices?[tool.rawValue] }
    public var modelSelection: AgentModelSelection { recordedModelSelection(for: tool) ?? AgentModelSelection() }
    public mutating func selectModel(_ value: AgentModelSelection, for provider: SessionTool) {
        guard provider != .shell, value.isValid else { return }
        if modelChoices == nil { modelChoices = [:] }
        modelChoices?[provider.rawValue] = value
    }
    public var hasValidModelChoices: Bool {
        modelChoices?.allSatisfy { entry in [SessionTool.codex, .claude].contains { $0.rawValue == entry.key } && entry.value.isValid } ?? true
    }
    private var imagePaths: [String]?
    public var images: [String] {
        get { imagePaths ?? [] }
        set { imagePaths = newValue.isEmpty ? nil : newValue }
    }
    public var isEmpty: Bool { prompt.isEmpty && images.isEmpty }
    public init(tool: SessionTool = .shell, prompt: String = "", images: [String] = []) {
        self.tool = tool; self.prompt = prompt; self.images = images
    }
}

public struct WorkspaceLocation: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var path: String
    public var scopePath: String
    public var checkoutIdentity: String?
    public var branch: String?
    public var commonRepository: String?
    public var isGit: Bool { checkoutIdentity != nil }
    public init(id: UUID = UUID(), path: String, scopePath: String? = nil,
                checkoutIdentity: String? = nil, branch: String? = nil, commonRepository: String? = nil) {
        self.id = id; self.path = path; self.scopePath = scopePath ?? path
        self.checkoutIdentity = checkoutIdentity; self.branch = branch; self.commonRepository = commonRepository
    }
}

public struct Project: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var location: WorkspaceLocation
    public var preferredSource: String?
    public var lastUsed: Date?
    public var isCollapsed: Bool?
    public init(id: UUID = UUID(), name: String, location: WorkspaceLocation) {
        self.id = id; self.name = name; self.location = location
    }
}

public struct TabFailure: Codable, Equatable, Sendable {
    public let phase: FailurePhase
    public let message: String
    public let recovery: FailureRecovery?
    public var noticeDismissed: Bool?
    public init(_ phase: FailurePhase, _ message: String, recovery: FailureRecovery? = nil) {
        self.phase = phase; self.message = message; self.recovery = recovery
    }
}

public struct WorkspaceTab: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title = "New tab"
    public var customTitle = false
    public var draft: TerminalDraft
    public var status: TabStatus = .draft
    public var failure: TabFailure?
    public var binding: SessionBinding?
    public var launch: LaunchSpec?
    public var startDirectory: String?
    public var promptDelivery: PromptDelivery = .none
    public var exitCode: Int?
    public var viewport: SessionViewport?
    public var activity: AgentActivity?
    public var projectAssociation: ProviderProjectAssociation?
    public var providerTitle: ProviderConversationTitle?
    public var startup: ProviderStartup?
    public init(id: UUID = UUID(), tool: SessionTool = .shell) { self.id = id; draft = TerminalDraft(tool: tool) }
    public var isEditable: Bool { status == .draft || (status == .failed && failure?.phase == .validation) }
}

public struct SplitLayout: Codable, Equatable, Sendable {
    public var first: UUID
    public var second: UUID
    public var fraction: Double = 0.5
    public init(first: UUID, second: UUID) { self.first = first; self.second = second }
}
public struct WorkspaceWindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct Workspace: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var projectID: UUID?
    public var selectedLocation: WorkspaceLocation
    public var anchor: WorkspaceLocation?
    public var title: String
    public var customTitle = false
    public var automaticTitle: AutomaticWorkspaceTitle?
    public var tabs: [WorkspaceTab]
    public var selectedTabID: UUID
    public var locationDraft: LocationDraft?
    public var locationOperationID: UUID?
    public var locationOwnerWorkspaceID: UUID?
    public var fileView: FileViewState?
    public var split: SplitLayout?
    public var catalogMetadata: ConversationMetadata?
    public var conversationID: ConversationID?
    public var conversationOwnershipAmbiguous: Bool?
    public var primaryTerminalID: UUID?
    public var support: SupportingPanelState?
    public var viewClosed: Bool?
    public var landingContext: String?
    public var lastViewedAt: Date?
    public var primaryTerminal: WorkspaceTab? { tabs.first { $0.id == primaryTerminalID } }
    public var directory: String { anchor?.path ?? selectedLocation.path }
    public var activityState: AgentActivityState? {
        guard let activity = primaryTerminal?.activity else { return nil }
        let state = activity.unread && activity.displayState.priority < AgentActivityState.finished.priority ? .finished : activity.displayState
        return state == .idle ? nil : state
    }
    public var needsAttention: Bool { primaryTerminal?.activity?.needsAttention == true }
    public init(location: WorkspaceLocation, projectID: UUID? = nil, tool: SessionTool = .shell, id: UUID = UUID(),
                title: String = WorkspaceNaming.friendly(excluding: [])) {
        self.id = id; self.projectID = projectID; selectedLocation = location
        self.title = title; automaticTitle = .friendly
        let tab = WorkspaceTab(tool: tool); tabs = [tab]; selectedTabID = tab.id; primaryTerminalID = tab.id; support = SupportingPanelState()
    }
}

extension WorkspaceState {
    @discardableResult public mutating func recordAgentEvent(_ event: AgentEvent, followTerminal: Bool = false) -> UUID? {
        guard event.isValid,
              var tab = workspaces.flatMap(\.tabs).first(where: { $0.binding?.id == event.bindingID || $0.launch?.operationID == event.bindingID }),
              ![TabStatus.draft, .preparing].contains(tab.status) else { return nil }
        if tab.status == .ended && ![AgentEventKind.finished, .failed, .interrupted, .detached].contains(event.kind) { return nil }
        var activity = tab.activity ?? AgentActivity(invocationID: event.invocationID, provider: event.provider)
        if activity.invocationID != event.invocationID {
            guard event.childID == nil else { return nil }
            let unread = activity.unread
            activity = AgentActivity(invocationID: event.invocationID, provider: event.provider)
            activity.manualUnread = unread
        }
        guard activity.apply(event) else { return nil }
        tab.startup?.observe(event)
        if tab.status == .ended { activity.disconnect() }
        if version >= 6, event.childID == nil, let sessionID = activity.sessionID, !sessionID.isEmpty,
           let owner = workspace(containing: tab.id), owner.primaryTerminalID == tab.id,
           let previous = owner.conversationID, previous != ConversationID(provider: activity.provider, sessionID: sessionID) {
            var next = self
            guard next.moveObservedConversation(tab: tab, event: event, followTerminal: followTerminal),
                  (try? next.validate()) != nil else { return nil }
            self = next
            return tab.id
        }
        updateTab(tab.id) {
            $0.activity = activity
            $0.startup = tab.startup
            if let metadata = $0.providerTitle, !$0.matchesConversation(metadata.id) { $0.providerTitle = nil }
        }
        if version >= 6, event.childID == nil, let sessionID = activity.sessionID, !sessionID.isEmpty,
           let workspaceID = separateAgentTerminal(tab.id, select: followTerminal) {
            associateConversation(ConversationID(provider: activity.provider, sessionID: sessionID), workspaceID: workspaceID)
        }
        return tab.id
    }
    public mutating func recordProjectAssociation(_ result: ProviderProjectAssociation, workspaceID: UUID,
                                                 primaryTerminalID: UUID, invocationID: UUID, operationID: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.acceptsProjectAssociation(result, primaryTerminalID: primaryTerminalID,
                                                  invocationID: invocationID, operationID: operationID) else { return }
        updateTab(primaryTerminalID) { $0.projectAssociation = result }
    }
    public mutating func acknowledgeAgent(_ id: UUID) { updateTab(id) { $0.activity?.acknowledge() } }
    @discardableResult public mutating func acknowledgeAgent(_ id: UUID, receipt: AgentCompletionReceipt, viewportAtBottom: Bool?) -> Bool {
        var acknowledged = false
        updateTab(id) { tab in acknowledged = tab.activity?.acknowledge(receipt, visible: true, viewportAtBottom: viewportAtBottom) == true }
        return acknowledged
    }
    public mutating func markAgentUnread(_ id: UUID) { updateTab(id) { $0.activity?.manualUnread = true } }
    public mutating func resetAgent(_ id: UUID) { updateTab(id) { $0.activity?.reset() } }
    public mutating func suspendAgentMonitoring(_ provider: SessionTool) {
        for tab in workspaces.flatMap(\.tabs) where tab.activity?.provider == provider {
            updateTab(tab.id) { $0.activity?.restore() }
        }
    }
    public mutating func clearAgentPreviews() {
        for tab in workspaces.flatMap(\.tabs) where tab.activity?.preview != nil {
            updateTab(tab.id) { $0.activity?.preview = nil }
        }
    }
    public mutating func restoreAgentActivity() {
        for tab in workspaces.flatMap(\.tabs) {
            if tab.activity != nil { updateTab(tab.id) { $0.activity?.restore() } }
            else if let binding = tab.binding, binding.tool != .shell {
                updateTab(tab.id) { $0.activity = AgentActivity(invocationID: binding.id, provider: binding.tool) }
            }
        }
    }
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    public var version = 8
    public var threadPresentations: [String: ThreadPresentation]?
    public var locations: LocationMetadata?
    public var projectDraft: ProjectCreationDraft?
    public private(set) var projects: [Project] = []
    public internal(set) var workspaces: [Workspace] = []
    public internal(set) var selectedWorkspaceID: UUID?
    public var lastTool: SessionTool = .shell
    public var lastAgentTool: SessionTool?
    private var lastModelChoices: [String: AgentModelSelection]?
    private var modelChoiceHistory: [String: [AgentModelSelection]]?
    public func rememberedModelSelection(for tool: SessionTool, model: String) -> AgentModelSelection? {
        modelChoiceHistory?[tool.rawValue]?.first { $0.model == model }
            ?? lastModelChoices?[tool.rawValue].flatMap { $0.model == model ? $0 : nil }
    }
    public func lastModelSelection(for tool: SessionTool) -> AgentModelSelection {
        lastModelChoices?[tool.rawValue] ?? AgentModelSelection()
    }
    public var sidebarCollapsed = false
    public var appearance: WorkspaceAppearance = .system
    public var windowFrame: WorkspaceWindowFrame?
    public init() {}
    public var selected: Workspace? { workspaces.first { $0.id == selectedWorkspaceID } }
    public var selectedTab: WorkspaceTab? {
        guard let workspace = selected else { return nil }
        return workspace.tabs.first { $0.id == workspace.selectedTabID }
    }
    public func tab(_ id: UUID) -> WorkspaceTab? { workspaces.lazy.compactMap { $0.tabs.first { $0.id == id } }.first }
    public func workspace(containing tabID: UUID) -> Workspace? { workspaces.first { $0.tabs.contains { $0.id == tabID } } }
    public var visibleTabIDs: [UUID] {
        guard let workspace = selected else { return [] }
        if version < 6 {
            if let split = workspace.split { return [split.first, split.second] }
            return [workspace.selectedTabID]
        }
        guard (version >= 8 || workspace.viewClosed != true), let primary = workspace.primaryTerminalID else { return [] }
        guard let panel = workspace.support else { return [primary] }
        switch panel.layout {
        case .collapsed: return [primary]
        case .split:
            if case .terminal(let id) = panel.selected?.target { return [primary, id] }
            return [primary]
        case .fullWidth:
            switch panel.resolvedFullWidthSelection {
            case .primary: return [primary]
            case .support(let supportID):
                if case .terminal(let id) = panel.tabs.first(where: { $0.id == supportID })?.target { return [id] }
                return []
            }
        }
    }

    @discardableResult public mutating func newWorkspace(directory: String) -> UUID {
        newWorkspace(location: WorkspaceLocation(path: directory))
    }
    @discardableResult public mutating func newWorkspace(location: WorkspaceLocation, projectID: UUID? = nil) -> UUID {
        let preferredAgent = lastAgentTool.flatMap { $0 == .shell ? nil : $0 }
        let tool = version < 6 ? lastTool : preferredAgent ?? (lastTool == .shell ? .codex : lastTool)
        var workspace = Workspace(location: location, projectID: projectID, tool: tool,
                                  title: WorkspaceNaming.friendly(excluding: workspaces.map(\.title)))
        if tool != .shell { workspace.tabs[0].draft.selectModel(lastModelSelection(for: tool), for: tool) }
        if version >= 7 { workspace.lastViewedAt = Date() }
        workspaces.append(workspace); selectedWorkspaceID = workspace.id
        if version >= 8 {
            let position = nextSidebarPosition()
            editThread(workspace.threadKey) { $0.sidebarPosition = position }
        }
        if let projectID { setProjectCollapsed(projectID, false) }
        return workspace.id
    }
    public mutating func setFileView(_ view: FileViewState, workspaceID: UUID) {
        guard view.isValid, let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].fileView = view
    }
    public mutating func selectWorkspace(_ id: UUID) {
        if let workspace = workspaces.first(where: { $0.id == id }) {
            if workspace.viewClosed == true { workspaces[workspaces.firstIndex { $0.id == id }!].viewClosed = false }
            if version >= 7, selectedWorkspaceID != id || workspace.viewClosed == true {
                workspaces[workspaces.firstIndex { $0.id == id }!].lastViewedAt = Date()
            }
            selectedWorkspaceID = id
            if version >= 8, !workspace.isLanding {
                editThread(workspace.threadKey) { $0.lastVisitedAt = Date() }
            }
            if let projectID = workspace.projectID { setProjectCollapsed(projectID, false) }
        }
    }
    public mutating func prepareEndedConversationResume(_ id: UUID) {
        guard let tab = tab(id), tab.status == .ended,
              tab.promptDelivery != .pending, tab.promptDelivery != .uncertain else { return }
        updateTab(id) {
            $0.binding = nil; $0.launch = nil; $0.status = .draft
            $0.failure = nil; $0.exitCode = nil; $0.viewport = nil
            $0.promptDelivery = .none
        }
    }
    public mutating func recordCatalogMetadata(_ metadata: ConversationMetadata, workspaceID: UUID, projectID: UUID?) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].conversationID == metadata.id else { return }
        workspaces[index].catalogMetadata = metadata
        rememberSidebarPositions([ConversationCatalogRecord(metadata: metadata, projectID: projectID)])
        let presentation = presentation(for: metadata.id.threadKey)
        if presentation.hasProjectOverride { workspaces[index].projectID = presentation.projectOverride }
        else if let projectID, projects.contains(where: { $0.id == projectID }) { workspaces[index].projectID = projectID }
        setProviderTitle(metadata.title, conversationID: metadata.id)
    }
    public mutating func setProjectCollapsed(_ id: UUID, _ collapsed: Bool) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].isCollapsed = collapsed
    }
    public mutating func toggleProjectCollapsed(_ id: UUID) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        setProjectCollapsed(id, project.isCollapsed != true)
    }
    public mutating func selectTab(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }),
              workspaces[index].tabs.contains(where: { $0.id == id }) else { return }
        let old = workspaces[index].selectedTabID
        if var split = workspaces[index].split, id != split.first, id != split.second {
            if old == split.first { split.first = id } else { split.second = id }
            workspaces[index].split = split
        }
        workspaces[index].selectedTabID = id
        if version >= 6, id == workspaces[index].primaryTerminalID {
            selectPrimaryContent(workspaceID: workspaces[index].id)
        } else if version >= 6, let supportID = workspaces[index].support?.tabs.first(where: { if case .terminal(let terminalID) = $0.target { return terminalID == id }; return false })?.id {
            selectSupport(supportID, workspaceID: workspaces[index].id)
        }
    }
    @discardableResult public mutating func newTab(workspaceID: UUID? = nil, startDirectory: String? = nil) -> UUID? {
        guard let index = workspaces.firstIndex(where: { $0.id == (workspaceID ?? selectedWorkspaceID) }) else { return nil }
        var tab = WorkspaceTab(tool: lastTool); tab.startDirectory = startDirectory
        workspaces[index].tabs.append(tab)
        if version >= 6 {
            var panel = workspaces[index].support ?? SupportingPanelState()
            panel.tabs.append(SupportingTab(id: tab.id, target: .terminal(tabID: tab.id), title: "Terminal"))
            panel.selectedTabID = tab.id; panel.fullWidthSelection = .support(tab.id)
            panel.layout = panel.layout == .collapsed ? panel.expandedLayout : panel.layout; workspaces[index].support = panel
        }
        if workspaces[index].id == selectedWorkspaceID { selectTab(tab.id) }
        else { workspaces[index].selectedTabID = tab.id }
        return tab.id
    }
    mutating func updateTab(_ id: UUID, _ change: (inout WorkspaceTab) -> Void) {
        for w in workspaces.indices {
            if let t = workspaces[w].tabs.firstIndex(where: { $0.id == id }) { change(&workspaces[w].tabs[t]); return }
        }
    }
    public mutating func apply(_ transition: WorkspaceTransition, to id: UUID) {
        guard let tab = tab(id) else { return }
        switch transition {
        case .preparing:
            guard tab.isEditable || (tab.status == .failed && tab.binding == nil) else { return }
            updateTab(id) { $0.status = .preparing; $0.failure = nil }
        case .intent(let spec, let prompt):
            guard tab.status == .preparing, tab.binding == nil,
                  tab.launch == nil || tab.launch == spec else { return }
            updateTab(id) {
                $0.launch = spec; $0.status = .launching; $0.promptDelivery = prompt
                $0.startup = spec.tool == .shell ? nil : ProviderStartup(operationID: spec.operationID, expectsPrompt: prompt != .none)
                if let metadata = $0.providerTitle, metadata.provider != spec.tool { $0.providerTitle = nil }
                if spec.tool != .shell && $0.activity == nil { $0.activity = AgentActivity(invocationID: spec.operationID, provider: spec.tool) }
            }
            if spec.tool != .shell, prompt != .none,
               let index = workspaces.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
               !workspaces[index].customTitle, workspaces[index].automaticTitle == .friendly,
               let title = WorkspaceNaming.promptTitle(tab.draft.prompt) {
                workspaces[index].title = title; workspaces[index].automaticTitle = .prompt
            }
        case .observed(let binding, let dead, let exitCode, let prompt):
            guard tab.launch?.operationID == binding.id || tab.binding?.id == binding.id else { return }
            updateTab(id) {
                $0.binding = binding; $0.status = dead ? .ended : .running
                $0.exitCode = exitCode; $0.failure = nil
                if dead { $0.activity?.disconnect() }
                if let prompt { $0.promptDelivery = prompt }
                if !$0.customTitle { $0.title = binding.tool.displayName }
            }
        case .failure(let status, let failure, let clearIntent):
            guard [.failed, .uncertain, .unavailable].contains(status) else { return }
            updateTab(id) {
                $0.status = status; $0.failure = failure
                if clearIntent { $0.launch = nil }
                if status == .uncertain && $0.promptDelivery != .none { $0.promptDelivery = .uncertain }
            }
        case .terminated: updateTab(id) { $0.status = .ended; $0.binding = nil; $0.activity?.disconnect() }
        }
    }
    public mutating func restoreInterruptedDrafts() {
        for tab in workspaces.flatMap(\.tabs) where tab.status == .preparing && tab.launch == nil && tab.binding == nil {
            updateTab(tab.id) { $0.status = .draft; $0.failure = nil }
        }
    }
    public mutating func cancelPreparation(_ id: UUID, restoring original: WorkspaceTab) {
        guard original.id == id, let current = tab(id), current.status == .preparing,
              current.launch == original.launch, current.binding == original.binding else { return }
        updateTab(id) { $0.status = original.status; $0.failure = original.failure }
    }
    public mutating func setViewport(_ viewport: SessionViewport?, tabID: UUID) {
        updateTab(tabID) { $0.viewport = viewport }
    }
    public mutating func editDraft(_ id: UUID, tool: SessionTool? = nil, prompt: String? = nil, images: [String]? = nil) {
        guard tab(id)?.isEditable == true else { return }
        let fallback = tool.map { lastModelSelection(for: $0) }
        updateTab(id) {
            if let tool {
                if $0.draft.tool != tool { $0.draft.fullAccess = false }
                $0.draft.tool = tool
                if $0.draft.recordedModelSelection(for: tool) == nil, let fallback { $0.draft.selectModel(fallback, for: tool) }
                if let metadata = $0.providerTitle, metadata.provider != tool { $0.providerTitle = nil }
            }
            if let prompt { $0.draft.prompt = prompt }
            if let images { $0.draft.images = images }
            $0.launch = nil; $0.failure = nil; $0.status = .draft
        }
        if let tool {
            lastTool = tool
            if tool != .shell { lastAgentTool = tool }
        }
    }
    public mutating func editModelSelection(_ id: UUID, selection: AgentModelSelection) {
        guard let tab = tab(id), tab.isEditable, tab.draft.tool != .shell, selection.isValid else { return }
        updateTab(id) {
            $0.draft.selectModel(selection, for: tab.draft.tool)
            $0.launch = nil; $0.failure = nil; $0.status = .draft
        }
        if lastModelChoices == nil { lastModelChoices = [:] }
        lastModelChoices?[tab.draft.tool.rawValue] = selection
        if selection.model != nil {
            if modelChoiceHistory == nil { modelChoiceHistory = [:] }
            var history = modelChoiceHistory?[tab.draft.tool.rawValue] ?? []
            history.removeAll { $0.model == selection.model }
            history.insert(selection, at: 0)
            modelChoiceHistory?[tab.draft.tool.rawValue] = Array(history.prefix(32))
        }
    }
    public mutating func editFullAccess(_ id: UUID, enabled: Bool) {
        guard let tab = tab(id), tab.isEditable, tab.draft.tool != .shell else { return }
        updateTab(id) {
            $0.draft.fullAccess = enabled
            $0.launch = nil; $0.failure = nil; $0.status = .draft
        }
    }
    public mutating func setLocation(_ location: WorkspaceLocation, projectID: UUID?, workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].anchor == nil,
              workspaces[index].tabs.allSatisfy({ $0.binding == nil && $0.launch == nil && $0.isEditable }) else { return }
        workspaces[index].selectedLocation = location; workspaces[index].projectID = projectID
        workspaces[index].locationDraft = nil; workspaces[index].locationOperationID = nil; workspaces[index].locationOwnerWorkspaceID = nil
    }
    public mutating func changeDirectory(_ directory: String) {
        guard let id = selectedWorkspaceID else { return }
        setLocation(WorkspaceLocation(path: directory), projectID: nil, workspaceID: id)
    }
    /// Refresh repository facts without moving the workspace or replacing its stable location ID.
    public mutating func refreshRepositoryMetadata(_ observed: WorkspaceLocation, workspaceID: UUID, scope: String? = nil) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        func refreshed(_ old: WorkspaceLocation) -> WorkspaceLocation {
            guard old.scopePath == (scope ?? observed.path) else { return old }
            var value = old
            // A newly discovered ancestor repository must not broaden the workspace's file scope.
            value.checkoutIdentity = observed.checkoutIdentity; value.commonRepository = observed.commonRepository
            value.branch = observed.branch
            return value
        }
        workspaces[index].selectedLocation = refreshed(workspaces[index].selectedLocation)
        if let anchor = workspaces[index].anchor { workspaces[index].anchor = refreshed(anchor) }
    }
    public mutating func relocateWorkspace(_ id: UUID, location: WorkspaceLocation) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[index].tabs.allSatisfy({ $0.status == .ended || $0.isEditable }) else { return }
        workspaces[index].selectedLocation = location
        if workspaces[index].anchor != nil { workspaces[index].anchor = location }
        workspaces[index].projectID = nil
        workspaces[index].locationDraft = nil; workspaces[index].locationOperationID = nil; workspaces[index].locationOwnerWorkspaceID = nil
        for tab in workspaces[index].tabs where tab.failure?.recovery == .locateFolder {
            updateTab(tab.id) { $0.status = .draft; $0.failure = nil; $0.launch = nil; $0.startDirectory = nil }
        }
    }
    public mutating func bindWorkspace(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), workspaces[index].anchor == nil else { return }
        workspaces[index].anchor = workspaces[index].selectedLocation
        if let projectID = workspaces[index].projectID, let p = projects.firstIndex(where: { $0.id == projectID }) { projects[p].lastUsed = Date() }
    }
    @discardableResult public mutating func registerProject(_ location: WorkspaceLocation) -> UUID {
        if let project = projects.first(where: { existing in
            existing.location.scopePath == location.scopePath || existing.location.projectAssociationKey == location.projectAssociationKey
        }) { return project.id }
        let p = Project(name: URL(fileURLWithPath: location.scopePath).lastPathComponent, location: location)
        projects.append(p); return p.id
    }
    public mutating func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        for key in Array((threadPresentations ?? [:]).keys) where threadPresentations?[key]?.projectOverride == id {
            threadPresentations?[key]?.projectOverride = nil
        }
        for w in workspaces.indices {
            if workspaces[w].projectID == id { workspaces[w].projectID = nil }
            if workspaces[w].landingContext == id.uuidString {
                workspaces[w].landingContext = nil; workspaces[w].viewClosed = false
                if !workspaces[w].customTitle { workspaces[w].title = "Draft"; workspaces[w].automaticTitle = .friendly }
            }
        }
    }
    public mutating func renameWorkspace(_ id: UUID, _ name: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        workspaces[index].title = name; workspaces[index].customTitle = true
    }
    public mutating func migrateWorkspaceNames() {
        for index in workspaces.indices where workspaces[index].automaticTitle == nil {
            if !workspaces[index].customTitle && WorkspaceNaming.isGeneric(workspaces[index].title) {
                workspaces[index].title = WorkspaceNaming.friendly(excluding: workspaces.map(\.title))
                workspaces[index].automaticTitle = .friendly
            } else { workspaces[index].automaticTitle = .legacy }
        }
    }
    public mutating func renameTab(_ id: UUID, _ name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        updateTab(id) { $0.title = name; $0.customTitle = true }
    }
    public mutating func setSplit(first: UUID, second: UUID) {
        guard first != second, let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }),
              [first, second].allSatisfy({ id in workspaces[index].tabs.contains { $0.id == id } }) else { return }
        workspaces[index].split = SplitLayout(first: first, second: second); workspaces[index].selectedTabID = second
    }
    public mutating func collapseSplit() {
        guard let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }) else { return }
        workspaces[index].split = nil
    }
    public mutating func setSplitFraction(_ fraction: Double) {
        guard let index = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }) else { return }
        workspaces[index].split?.fraction = min(0.8, max(0.2, fraction))
    }
    public mutating func closeTab(_ id: UUID) {
        guard let w = workspaces.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
              let t = workspaces[w].tabs.firstIndex(where: { $0.id == id }) else { return }
        let workspaceID = workspaces[w].id
        let supports = workspaces[w].support?.tabs.filter {
            if case .terminal(let terminalID) = $0.target { return terminalID == id }; return false
        }.map(\.id) ?? []
        for supportID in supports { closeSupport(supportID, workspaceID: workspaceID) }
        workspaces[w].tabs.remove(at: t)
        if workspaces[w].primaryTerminalID == id { workspaces[w].primaryTerminalID = workspaces[w].tabs.first?.id }
        if let primary = workspaces[w].primaryTerminalID {
            let promotedSupports = workspaces[w].support?.tabs.filter {
                if case .terminal(let terminalID) = $0.target { return terminalID == primary }; return false
            }.map(\.id) ?? []
            for supportID in promotedSupports { closeSupport(supportID, workspaceID: workspaceID) }
        }
        if let split = workspaces[w].split, split.first == id || split.second == id { workspaces[w].split = nil }
        if workspaces[w].tabs.isEmpty {
            closeWorkspace(workspaces[w].id)
        } else if workspaces[w].selectedTabID == id { workspaces[w].selectedTabID = workspaces[w].tabs[min(t, workspaces[w].tabs.count - 1)].id }
    }
    public mutating func closeWorkspace(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces.remove(at: index)
        if selectedWorkspaceID == id { selectedWorkspaceID = workspaces.isEmpty ? nil : workspaces[min(index, workspaces.count - 1)].id }
    }

    public mutating func migrateLocations() {
        version = 2
        if locations == nil { locations = LocationMetadata() }
        for location in projects.map(\.location) + workspaces.flatMap({ [$0.selectedLocation] + ($0.anchor.map { [$0] } ?? []) }) where location.isGit {
            recordCheckout(location)
        }
    }
    public mutating func recordCheckout(_ location: WorkspaceLocation, createdBy: UUID? = nil, commit: String? = nil) {
        if locations == nil { locations = LocationMetadata() }
        let index = locations!.checkouts.firstIndex { $0.location.checkoutIdentity == location.checkoutIdentity }
        let root = WorkspaceLocation(id: index.map { locations!.checkouts[$0].location.id } ?? location.id,
            path: location.scopePath, scopePath: location.scopePath, checkoutIdentity: location.checkoutIdentity,
            branch: location.branch, commonRepository: location.commonRepository)
        if let index {
            locations!.checkouts[index].location = root
            if let createdBy { locations!.checkouts[index].createdBy = createdBy; locations!.checkouts[index].creationCommit = commit }
        } else { locations!.checkouts.append(CheckoutRecord(location: root, createdBy: createdBy, creationCommit: commit)) }
    }
    public mutating func recordOperation(_ operation: LocationOperation) {
        if locations == nil { locations = LocationMetadata() }
        let isNew = !locations!.operations.contains { $0.id == operation.id }
        if let index = locations!.operations.firstIndex(where: { $0.id == operation.id }) { locations!.operations[index] = operation }
        else { locations!.operations.append(operation) }
        if isNew, let id = operation.request.workspaceID, let index = workspaces.firstIndex(where: { $0.id == id }) {
            workspaces[index].locationOperationID = operation.id
        }
    }
    public mutating func dismissOperationNotice(_ id: UUID) {
        guard let index = locations?.operations.firstIndex(where: { $0.id == id }) else { return }
        locations?.operations[index].noticeDismissed = true
    }
    public mutating func dismissFailureNotice(_ tabID: UUID) {
        updateTab(tabID) { $0.failure?.noticeDismissed = true }
    }
    public mutating func editLocation(_ draft: LocationDraft, workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }), workspaces[index].anchor == nil else { return }
        if draft.mode != workspaces[index].locationDraft?.mode, draft.mode == .local {
            let tabID = workspaces[index].primaryTerminalID ?? workspaces[index].selectedTabID
            updateTab(tabID) { tab in
                if tab.status == .failed && tab.binding == nil && tab.launch == nil {
                    tab.status = .draft; tab.failure = nil
                }
            }
        }
        workspaces[index].locationDraft = draft
    }
    public mutating func refreshProject(_ id: UUID, location: WorkspaceLocation) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].location.commonRepository = location.commonRepository
        if projects[index].location.checkoutIdentity == location.checkoutIdentity { projects[index].location.branch = location.branch }
        for index in workspaces.indices where workspaces[index].projectID == id && workspaces[index].anchor == nil && workspaces[index].selectedLocation.checkoutIdentity == location.checkoutIdentity {
            workspaces[index].selectedLocation.commonRepository = location.commonRepository
            workspaces[index].selectedLocation.branch = location.branch
        }
    }
    public mutating func preferSource(_ source: String, projectID: UUID) {
        if let index = projects.firstIndex(where: { $0.id == projectID }) { projects[index].preferredSource = source }
    }
    public mutating func acceptPreparedLocation(_ location: WorkspaceLocation, workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }), workspaces[index].anchor == nil else { return }
        workspaces[index].selectedLocation = location
        workspaces[index].locationDraft = nil
    }
    public mutating func removeCheckout(_ identity: String) {
        locations?.checkouts.removeAll { $0.location.checkoutIdentity == identity }
    }
    public func validate() throws {
        let tabs = workspaces.flatMap(\.tabs)
        for operation in locations?.operations ?? [] { try operation.request.validate() }
        guard [1, 2, 3, 4, 5, 6, 7, 8].contains(version), lastAgentTool != .shell,
              lastModelChoices?.values.allSatisfy(\.isValid) != false,
              modelChoiceHistory?.allSatisfy({ provider, choices in
                  [SessionTool.codex.rawValue, SessionTool.claude.rawValue].contains(provider) && choices.count <= 32 &&
                  choices.allSatisfy { $0.isValid && $0.model != nil } && Set(choices.compactMap(\.model)).count == choices.count
              }) != false,
              tabs.allSatisfy({ $0.draft.hasValidModelChoices }),
              Set(locations?.operations.map(\.id) ?? []).count == (locations?.operations.count ?? 0),
              Set(locations?.checkouts.map(\.id) ?? []).count == (locations?.checkouts.count ?? 0),
              (locations?.operations.allSatisfy { $0.request.destination.hasPrefix("/") && !$0.request.destination.contains("\0") } ?? true),
              tabs.allSatisfy({ $0.viewport?.anchor?.isValid != false && $0.activity?.isValid != false && $0.providerTitle?.isValid != false }), Set(workspaces.map(\.id)).count == workspaces.count,
              Set(tabs.map(\.id)).count == tabs.count, Set(projects.map(\.id)).count == projects.count,
              selectedWorkspaceID == nil || workspaces.contains(where: { $0.id == selectedWorkspaceID }),
              workspaces.allSatisfy({ w in
                  (version < 6 || w.isValidConversationWorkspace) && (w.fileView?.isValid ?? true) && !w.tabs.isEmpty && w.tabs.contains { $0.id == w.selectedTabID } &&
                  (w.projectID == nil || projects.contains { $0.id == w.projectID }) &&
                  (w.split.map { split in split.first != split.second && [split.first, split.second].allSatisfy { id in w.tabs.contains { $0.id == id } } } ?? true)
              }) else { throw LaunchError.invalid("Workspace metadata is inconsistent. The saved database was preserved.") }
    }
}

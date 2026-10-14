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
    public init(tool: SessionTool = .shell, prompt: String = "") { self.tool = tool; self.prompt = prompt }
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
    public var tabs: [WorkspaceTab]
    public var selectedTabID: UUID
    public var locationDraft: LocationDraft?
    public var locationOperationID: UUID?
    public var fileView: FileViewState?
    public var split: SplitLayout?
    public var directory: String { anchor?.path ?? selectedLocation.path }
    public init(location: WorkspaceLocation, projectID: UUID? = nil, tool: SessionTool = .shell, id: UUID = UUID()) {
        self.id = id; self.projectID = projectID; selectedLocation = location
        title = "New workspace"
        let tab = WorkspaceTab(tool: tool); tabs = [tab]; selectedTabID = tab.id
    }
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    public var version = 3
    public var locations: LocationMetadata?
    public var projectDraft: ProjectCreationDraft?
    public private(set) var projects: [Project] = []
    public private(set) var workspaces: [Workspace] = []
    public private(set) var selectedWorkspaceID: UUID?
    public var lastTool: SessionTool = .shell
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
        guard let w = selected else { return [] }
        if let split = w.split { return [split.first, split.second] }
        return [w.selectedTabID]
    }

    @discardableResult public mutating func newWorkspace(directory: String) -> UUID {
        newWorkspace(location: WorkspaceLocation(path: directory))
    }
    @discardableResult public mutating func newWorkspace(location: WorkspaceLocation, projectID: UUID? = nil) -> UUID {
        let workspace = Workspace(location: location, projectID: projectID, tool: lastTool)
        workspaces.append(workspace); selectedWorkspaceID = workspace.id
        if let projectID { setProjectCollapsed(projectID, false) }
        return workspace.id
    }
    public mutating func setFileView(_ view: FileViewState, workspaceID: UUID) {
        guard view.isValid, let index = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        workspaces[index].fileView = view
    }
    public mutating func selectWorkspace(_ id: UUID) {
        if let workspace = workspaces.first(where: { $0.id == id }) {
            selectedWorkspaceID = id
            if let projectID = workspace.projectID { setProjectCollapsed(projectID, false) }
        }
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
    }
    @discardableResult public mutating func newTab(workspaceID: UUID? = nil, startDirectory: String? = nil) -> UUID? {
        guard let index = workspaces.firstIndex(where: { $0.id == (workspaceID ?? selectedWorkspaceID) }) else { return nil }
        var tab = WorkspaceTab(tool: lastTool); tab.startDirectory = startDirectory
        workspaces[index].tabs.append(tab)
        if workspaces[index].id == selectedWorkspaceID { selectTab(tab.id) }
        else { workspaces[index].selectedTabID = tab.id }
        return tab.id
    }
    private mutating func updateTab(_ id: UUID, _ change: (inout WorkspaceTab) -> Void) {
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
            updateTab(id) { $0.launch = spec; $0.status = .launching; $0.promptDelivery = prompt }
        case .observed(let binding, let dead, let exitCode, let prompt):
            guard tab.launch?.operationID == binding.id || tab.binding?.id == binding.id else { return }
            updateTab(id) {
                $0.binding = binding; $0.status = dead ? .ended : .running
                $0.exitCode = exitCode; $0.failure = nil
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
        case .terminated: updateTab(id) { $0.status = .ended; $0.binding = nil }
        }
    }
    public mutating func restoreInterruptedDrafts() {
        for tab in workspaces.flatMap(\.tabs) where tab.status == .preparing && tab.launch == nil && tab.binding == nil {
            updateTab(tab.id) { $0.status = .draft; $0.failure = nil }
        }
    }
    public mutating func setViewport(_ viewport: SessionViewport?, tabID: UUID) {
        updateTab(tabID) { $0.viewport = viewport }
    }
    public mutating func editDraft(_ id: UUID, tool: SessionTool? = nil, prompt: String? = nil) {
        guard tab(id)?.isEditable == true else { return }
        updateTab(id) {
            if let tool { $0.draft.tool = tool }
            if let prompt { $0.draft.prompt = prompt }
            $0.launch = nil; $0.failure = nil; $0.status = .draft
        }
        if let tool { lastTool = tool }
    }
    public mutating func setLocation(_ location: WorkspaceLocation, projectID: UUID?, workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }),
              workspaces[index].anchor == nil,
              workspaces[index].tabs.allSatisfy({ $0.binding == nil && $0.launch == nil && $0.isEditable }) else { return }
        workspaces[index].selectedLocation = location; workspaces[index].projectID = projectID
        workspaces[index].locationDraft = nil; workspaces[index].locationOperationID = nil
    }
    public mutating func changeDirectory(_ directory: String) {
        guard let id = selectedWorkspaceID else { return }
        setLocation(WorkspaceLocation(path: directory), projectID: nil, workspaceID: id)
    }
    public mutating func relocateWorkspace(_ id: UUID, location: WorkspaceLocation) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }),
              workspaces[index].tabs.allSatisfy({ $0.status == .ended || $0.isEditable }) else { return }
        workspaces[index].selectedLocation = location
        if workspaces[index].anchor != nil { workspaces[index].anchor = location }
        workspaces[index].projectID = nil
        workspaces[index].locationDraft = nil; workspaces[index].locationOperationID = nil
        for tab in workspaces[index].tabs where tab.failure?.recovery == .locateFolder {
            updateTab(tab.id) { $0.status = .draft; $0.failure = nil; $0.launch = nil; $0.startDirectory = nil }
        }
    }
    public mutating func bindWorkspace(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), workspaces[index].anchor == nil else { return }
        workspaces[index].anchor = workspaces[index].selectedLocation
        if !workspaces[index].customTitle {
            let path = workspaces[index].selectedLocation.path
            workspaces[index].title = path == FileManager.default.homeDirectoryForCurrentUser.path ? "Home" : URL(fileURLWithPath: path).lastPathComponent
        }
        if let projectID = workspaces[index].projectID, let p = projects.firstIndex(where: { $0.id == projectID }) { projects[p].lastUsed = Date() }
    }
    @discardableResult public mutating func registerProject(_ location: WorkspaceLocation) -> UUID {
        if let project = projects.first(where: { existing in
            existing.location.scopePath == location.scopePath ||
                (location.commonRepository != nil && (existing.location.commonRepository == location.commonRepository || existing.location.checkoutIdentity == location.commonRepository))
        }) { return project.id }
        let p = Project(name: URL(fileURLWithPath: location.scopePath).lastPathComponent, location: location)
        projects.append(p); return p.id
    }
    public mutating func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        for w in workspaces.indices where workspaces[w].projectID == id { workspaces[w].projectID = nil }
    }
    public mutating func renameWorkspace(_ id: UUID, _ name: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        workspaces[index].title = name; workspaces[index].customTitle = true
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
        workspaces[w].tabs.remove(at: t)
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
    public mutating func editLocation(_ draft: LocationDraft, workspaceID: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceID }), workspaces[index].anchor == nil else { return }
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
        guard [1, 2, 3].contains(version),
              Set(locations?.operations.map(\.id) ?? []).count == (locations?.operations.count ?? 0),
              Set(locations?.checkouts.map(\.id) ?? []).count == (locations?.checkouts.count ?? 0),
              (locations?.operations.allSatisfy { $0.request.destination.hasPrefix("/") && !$0.request.destination.contains("\0") } ?? true),
              tabs.allSatisfy({ $0.viewport?.anchor?.isValid != false }), Set(workspaces.map(\.id)).count == workspaces.count,
              Set(tabs.map(\.id)).count == tabs.count, Set(projects.map(\.id)).count == projects.count,
              selectedWorkspaceID == nil || workspaces.contains(where: { $0.id == selectedWorkspaceID }),
              workspaces.allSatisfy({ w in
                  (w.fileView?.isValid ?? true) && !w.tabs.isEmpty && w.tabs.contains { $0.id == w.selectedTabID } &&
                  (w.projectID == nil || projects.contains { $0.id == w.projectID }) &&
                  (w.split.map { split in split.first != split.second && [split.first, split.second].allSatisfy { id in w.tabs.contains { $0.id == id } } } ?? true)
              }) else { throw LaunchError.invalid("Workspace metadata is inconsistent. The saved database was preserved.") }
    }
}

import AppKit
import GhosttyKit
import SpookkyCore
import SpookkyRuntime

@MainActor final class TerminalSurfaceManager {
    private let appearanceFollower: GhosttyAppearanceFollower
    private var appearanceTask: Task<Void, Never>?
    private var appearancePending = false
    private var desiredProfile: GhosttyAppearanceProfile?
    private var desiredAppearance: GhosttyAppearance { (darkTheme == false ? desiredProfile?.light : desiredProfile?.dark) ?? GhosttyAppearance(export: "") }
    private var acceptedAppearance: GhosttyAppearance?
    private var acceptedDisplay: DisplayPreferences?
    var onAppearanceStatus: ((String) -> Void)?
    func startFollowingAppearance() {
        appearanceFollower.onAppearance = { [weak self] appearance in self?.desiredProfile = appearance; self?.refreshAppearance() }
        appearanceFollower.onError = { [weak self] in self?.onAppearanceStatus?($0) }
        appearanceFollower.start()
    }
    func stopFollowingAppearance() { appearanceFollower.stop(); appearanceTask?.cancel() }
    func refreshAppearance() {
        appearancePending = true
        guard appearanceTask == nil else { return }
        appearanceTask = Task { [weak self] in
            guard let self else { return }
            defer { appearanceTask = nil }
            while appearancePending && !Task.isCancelled {
                appearancePending = false
                let candidate = desiredAppearance, display = DisplayMetrics.preferences
                do {
                    if acceptedAppearance != candidate || acceptedDisplay != display {
                        try await engine.applyAppearance(candidate, preferences: display, views: { [weak self] in Array(self?.views.values ?? [:].values) })
                        acceptedAppearance = candidate; acceptedDisplay = display
                    }
                    onAppearanceStatus?("Following Ghostty appearance. Font adjustment applies only to Spookky.")
                } catch {
                    onAppearanceStatus?(error.localizedDescription)
                }
            }
        }
    }
    private let engine: GhosttyEngine
    private let runtime: any SessionRuntime
    private let root: URL
    private let executable: String
    private var views: [UUID: TerminalHostView] = [:]
    private var recent: [UUID] = []
    private var generation = 0
    private var darkTheme: Bool?
    private var bindings: [UUID: SessionBinding] = [:]
    private var pendingViewports: [UUID: SessionViewport] = [:]
    private var resizing: [UUID: UUID] = [:]
    private var resizeTasks: [UUID: Task<Void, Never>] = [:]
    private var resizeAnchors: [UUID: SessionViewport] = [:]
    func isResizing(_ id: UUID) -> Bool { resizing[id] != nil }
    var onExit: ((UUID) -> Void)?
    var onFocus: ((UUID) -> Void)?
    var onOpenURL: ((UUID, URL) -> Bool)?
    var onViewport: ((UUID, SessionViewport?) -> Void)?
    var onViewportFailure: ((UUID, Error) -> Void)?

    init(engine: GhosttyEngine, runtime: any SessionRuntime, executable: String, root: URL) {
        appearanceFollower = GhosttyAppearanceFollower(cache: root.appendingPathComponent("terminal-appearance.json"))
        self.engine = engine; self.runtime = runtime; self.executable = executable; self.root = root
    }
    func invalidate() { generation += 1 }
    func view(_ id: UUID) -> TerminalHostView? { views[id] }
    func clientExited(_ id: UUID) -> Bool {
        guard let surface = views[id]?.surface else { return false }
        return ghostty_surface_process_exited(surface)
    }
    var count: Int { views.count }
    var resizeTaskCount: Int { resizeTasks.count }
    var resizeAnchorCount: Int { resizeAnchors.count }
    func fixtureHistoryMarker(_ id: UUID) -> Int? {
        let prefix = "SPOOKKY_M1_FIXTURE_HISTORY_"
        guard let line = views[id]?.visibleText().split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) }),
              let token = line.split(separator: " ").first else { return nil }
        return Int(token.dropFirst(prefix.count))
    }
    func observedViewport(_ id: UUID) async throws -> SessionViewport? {
        guard let owner = runtime as? any SessionViewportRuntime, let binding = bindings[id] else { return nil }
        return try await owner.viewport(binding)
    }
    func scrollFixtureHistory(_ id: UUID, offset: Int? = 25) async throws {
        guard let owner = runtime as? any SessionViewportRuntime,
              let binding = bindings[id], let surface = views[id]?.surface else { throw LaunchError.invalid("Fixture terminal is unavailable.") }
        let size = ghostty_surface_size(surface)
        try await owner.restoreViewport(SessionViewport(historySize: 0, scrollOffset: 0), binding: binding, columns: Int(size.columns), rows: Int(size.rows))
        let baseline = try await owner.viewport(binding)
        let distance = offset ?? max(1, (baseline?.historySize ?? 0) / 2)
        try await owner.restoreViewport(SessionViewport(historySize: baseline?.historySize ?? 0, scrollOffset: distance), binding: binding, columns: Int(size.columns), rows: Int(size.rows))
        await captureViewport(id)
    }
    func prepare(_ tabs: [WorkspaceTab], sizes: [UUID: NSSize] = [:]) async throws -> [UUID: TerminalHostView]? {
        generation += 1
        let current = generation
        let visible = Set(tabs.map(\.id))
        // Full-width tools can hide both panes of the current terminal split.
        let hidden = Set(recent.reversed().filter { !visible.contains($0) && views[$0] != nil }.prefix(max(1, 2 - visible.count)))
        for id in Array(views.keys) where !visible.contains(id) && !hidden.contains(id) {
            await captureViewport(id)
            guard current == generation else { return nil }
            release(id)
        }
        var result: [UUID: TerminalHostView] = [:]
        for tab in tabs {
            guard let binding = tab.binding else { continue }
            bindings[tab.id] = binding
            if let view = views[tab.id] { result[tab.id] = view; continue }
            let args = try await runtime.attachmentArguments(binding)
            guard current == generation else { return nil }
            let command = ShellCommand.render([executable] + args)
            let view = try TerminalHostView(engine: engine, command: command, directory: root.path, initialSize: sizes[tab.id])
            let tabID = tab.id
            view.onExit = { [weak self] _ in self?.onExit?(tabID) }
            view.onFocus = { [weak self] in self?.onFocus?(tabID) }
            view.onOpenURL = { [weak self] url in self?.onOpenURL?(tabID, url) ?? false }
            if let mouseOwner = runtime as? any SessionMouseRuntime {
                view.applicationCapturesMouse = { try await mouseOwner.applicationCapturesMouse(binding) }
            }
            view.onViewportInteraction = { [weak self] in
                self?.resizeAnchors[tabID] = nil; self?.resizeTasks[tabID]?.cancel()
            }
            view.onResize = { [weak self, weak view] apply, finish in
                let request = UUID()
                self?.resizing[tabID] = request
                let task = Task { @MainActor in
                    defer {
                        if self?.resizing[tabID] == request { self?.resizing[tabID] = nil; self?.resizeTasks[tabID] = nil }
                        finish()
                    }
                    guard let self, let view, self.views[tabID] === view,
                          let owner = self.runtime as? any SessionViewportRuntime else { apply(); return }
                    do {
                        let viewport = try await owner.viewport(binding)
                        try Task.checkCancellation()
                        guard self.views[tabID] === view else { return }
                        if viewport == nil { self.resizeAnchors[tabID] = nil }
                        else if self.resizeAnchors[tabID] == nil { self.resizeAnchors[tabID] = viewport }
                        apply()
                        if let viewport = self.resizeAnchors[tabID], try await owner.viewport(binding) != nil {
                            try Task.checkCancellation()
                            guard self.views[tabID] === view, let surface = view.surface else { return }
                            let size = ghostty_surface_size(surface)
                            try await owner.restoreViewport(viewport, binding: binding, columns: Int(size.columns), rows: Int(size.rows))
                        }
                    } catch is CancellationError { apply() }
                    catch { apply(); self.onViewportFailure?(tabID, error) }
                }
                self?.resizeTasks[tabID] = task
            }
            views[tab.id] = view; result[tab.id] = view
            if let viewport = tab.viewport { pendingViewports[tab.id] = viewport }
        }
        guard current == generation else { return nil }
        for id in tabs.map(\.id) { recent.removeAll { $0 == id }; recent.append(id) }
        return result
    }
    func release(_ id: UUID) {
        resizeTasks[id]?.cancel()
        views[id]?.removeFromSuperview(); views[id]?.releaseSurface(); views[id] = nil
        recent.removeAll { $0 == id }
        bindings[id] = nil; pendingViewports[id] = nil
        resizeAnchors[id] = nil
    }
    func releaseAll() { invalidate(); for id in Array(views.keys) { release(id) } }
    func captureViewports() async { for id in Array(views.keys) { await captureViewport(id) } }
    private func captureViewport(_ id: UUID) async {
        guard let owner = runtime as? any SessionViewportRuntime, let binding = bindings[id] else { return }
        do {
            let observed = try await owner.viewport(binding)
            let retained = resizeAnchors[id]
            let captured: SessionViewport?
            if let observed, let retained, observed.anchor?.digest == retained.anchor?.digest {
                captured = retained
            } else {
                captured = observed
            }
            onViewport?(id, captured)
        } catch { onViewportFailure?(id, error) }
    }
    func restoreViewports(_ ids: [UUID]) async throws {
        let current = generation
        guard let owner = runtime as? any SessionViewportRuntime else { return }
        for id in ids {
            try Task.checkCancellation()
            guard current == generation else { return }
            guard let viewport = pendingViewports.removeValue(forKey: id),
                  let binding = bindings[id], let surface = views[id]?.surface else { continue }
            let size = ghostty_surface_size(surface)
            try await owner.restoreViewport(viewport, binding: binding, columns: Int(size.columns), rows: Int(size.rows))
            try Task.checkCancellation()
            guard current == generation, views[id]?.surface == surface else { return }
            resizeAnchors[id] = viewport
        }
    }
    func setFocus(_ focused: Bool) {
        ghostty_app_set_focus(engine.app, focused)
    }
    func setTheme(dark: Bool) {
        guard darkTheme != dark else { return }; darkTheme = dark
        if desiredProfile != nil { refreshAppearance() }
        Task {
            do { try await engine.setTheme(dark: dark, views: Array(views.values)) }
            catch { darkTheme = nil }
        }
    }
}

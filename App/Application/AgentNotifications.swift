import AppKit
@preconcurrency import UserNotifications
import SpookkyCore

@MainActor final class AgentNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onFocus: ((UUID) -> Void)?
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var sound: NSSound?
    private var permissionTask: Task<Bool, Never>?
    private var unavailableReason: String?
    private let fixture = ApplicationArguments.values.contains("--workspace-benchmark-count") || ApplicationArguments.values.contains("--workspace-benchmark-restoring")
    private var focusObservers: [NSObjectProtocol] = []
    private var motionObserver: NSObjectProtocol?

    override init() { super.init(); center.delegate = self }

    func watchFocus(_ callback: @escaping @MainActor () -> Void) {
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in callback() }
            })
        }
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in callback() }
        }
    }
    func requestPermission() {
        guard permissionTask == nil, !fixture else { return }
        permissionTask = Task {
            do { return try await center.requestAuthorization(options: [.alert, .badge]) }
            catch { unavailableReason = error.localizedDescription; return false }
        }
    }
    func updateBadge(_ state: WorkspaceState, preferences: AgentNotificationPreferences) {
        let count = state.workspaces.filter(\.needsAttention).count
        NSApp.dockTile.badgeLabel = preferences.dockBadge && count > 0 ? String(count) : nil
    }
    func clear(_ tabID: UUID) {
        pending.removeValue(forKey: tabID)?.cancel()
        center.removeDeliveredNotifications(withIdentifiers: [tabID.uuidString])
        center.removePendingNotificationRequests(withIdentifiers: [tabID.uuidString])
    }
    func schedule(tabID: UUID, state: AgentActivityState, workspace: String, provider: String, preview: String?,
                  preferences: AgentNotificationPreferences, stillRelevant: @escaping @MainActor () -> Bool) {
        pending.removeValue(forKey: tabID)?.cancel()
        guard state.needsAttention else { clear(tabID); return }
        guard preferences.banner(state) || preferences.playsSound(state) else { return }
        pending[tabID] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled, stillRelevant() else { return }
            if preferences.playsSound(state), let value = NSSound(named: NSSound.Name(preferences.sound)) {
                value.volume = min(1, max(0, preferences.volume)); self.sound = value; value.play()
            }
            if preferences.banner(state) {
                _ = await self.show(tabID: tabID, workspace: workspace, provider: provider, state: state,
                                    preview: preferences.previews ? preview : nil, stillRelevant: stillRelevant)
            }
            if !Task.isCancelled { self.pending.removeValue(forKey: tabID) }
        }
    }
    private func show(tabID: UUID?, workspace: String, provider: String, state: AgentActivityState, preview: String?, stillRelevant: @MainActor () -> Bool = { true }) async -> Bool {
        guard !fixture else { return false }
        requestPermission()
        var authorized = await permissionTask?.value ?? false
        if !authorized { authorized = await center.notificationSettings().authorizationStatus == .authorized }
        guard authorized, !Task.isCancelled, stillRelevant() else { return false }
        let content = UNMutableNotificationContent()
        content.title = workspace
        content.subtitle = provider + " · " + (state == .finished ? "Turn finished" : state.label)
        content.body = preview.flatMap { $0.isEmpty ? nil : $0 } ?? "Open terminal"
        if let tabID { content.userInfo = ["tabID": tabID.uuidString] }
        let id = tabID?.uuidString ?? "spookky-test"
        center.removeDeliveredNotifications(withIdentifiers: [id])
        do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)); unavailableReason = nil; return true }
        catch { unavailableReason = error.localizedDescription; return false }
    }
    func test() async -> String {
        let sent = await show(tabID: nil, workspace: "Spookky", provider: "Notifications", state: .needsInput, preview: "Your notification settings are ready.")
        if sent { return "Test notification sent to macOS." }
        if let unavailableReason { return "Notifications: " + unavailableReason }
        let status = await center.notificationSettings().authorizationStatus
        return status == .denied ? "Notifications are off for Spookky in System Settings." : "macOS has not authorized notifications for this build."
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["tabID"] as? String).flatMap(UUID.init(uuidString:))
        if let id { Task { @MainActor [weak self] in self?.onFocus?(id) } }
        completionHandler()
    }
    deinit {
        for observer in focusObservers { NotificationCenter.default.removeObserver(observer) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
    }
}

@MainActor enum AgentIndicator {
    static func symbol(_ state: AgentActivityState) -> String? {
        switch state {
        case .unknown: "questionmark.circle"
        case .idle: nil
        case .working: "arrow.triangle.2.circlepath"
        case .needsInput: "exclamationmark.circle.fill"
        case .finished: "circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .interrupted: "pause.circle"
        }
    }
    static func color(_ state: AgentActivityState) -> NSColor {
        switch state {
        case .working, .needsInput: SpookkyPalette.warning
        case .finished: SpookkyPalette.success
        case .failed: SpookkyPalette.destructive
        default: SpookkyPalette.metadata
        }
    }
    static func detail(_ activity: AgentActivity) -> String {
        var parts = [activity.provider.displayName, activity.displayState.label]
        if activity.unread && activity.displayState != .finished { parts.append("Unread completion") }
        if !activity.children.isEmpty { parts.append(childLabel(activity.children.count) + " reported") }
        parts += activity.children.prefix(8).map { ($0.type ?? "Subagent") + " · " + $0.id }
        if let preview = activity.preview { parts.append(preview) }
        return parts.joined(separator: " · ")
    }
    static func childLabel(_ count: Int) -> String { "\(count) subagent" + (count == 1 ? "" : "s") }
    static func animate(_ view: NSImageView, working: Bool) {
        let visible = view.window?.occlusionState.contains(.visible) == true && !view.isHiddenOrHasHiddenAncestor
        var spinner = view.subviews.first { $0 is NSProgressIndicator } as? NSProgressIndicator
        if working && visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if spinner == nil {
                let progress = NSProgressIndicator(frame: view.bounds)
                progress.style = .spinning; progress.controlSize = .small; progress.isIndeterminate = true
                progress.isDisplayedWhenStopped = false; progress.autoresizingMask = [.width, .height]
                progress.setAccessibilityElement(false); view.addSubview(progress); spinner = progress
            }
            view.image = nil; spinner?.startAnimation(nil)
        } else {
            spinner?.stopAnimation(nil)
            if working { view.image = NSImage(systemSymbolName: symbol(.working)!, accessibilityDescription: nil) }
        }
    }
}

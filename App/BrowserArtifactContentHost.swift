import AppKit
import WebKit
import CryptoKit
import SpookkyCore

@MainActor final class BrowserArtifactContentHost: SupportingContentHost {
    private var views: [UUID: NSView] = [:]
    private let websiteData: WKWebsiteDataStore
    var materializedCount: Int { views.count }
    var browserCount: Int { views.values.filter { $0 is SupportingBrowserView }.count }

    init(identity: String) {
        let digest = Array(SHA256.hash(data: Data(identity.utf8)))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let uuid = String(hex.prefix(8)) + "-" + String(hex.dropFirst(8).prefix(4)) + "-" + String(hex.dropFirst(12).prefix(4)) + "-" + String(hex.dropFirst(16).prefix(4)) + "-" + String(hex.dropFirst(20))
        websiteData = WKWebsiteDataStore(forIdentifier: UUID(uuidString: uuid)!)
    }
    func view(for tab: SupportingTab, workspace: Workspace, update: @escaping (SupportingTarget, String?) -> Void) -> NSView? {
        if let existing = views[tab.id] { return existing }
        let view: NSView
        switch tab.target {
        case .browser(let url): view = SupportingBrowserView(address: url, websiteData: websiteData, update: update)
        case .artifact(let path): view = SupportingArtifactView(path: path)
        default: return nil
        }
        views[tab.id] = view
        return view
    }
    func retainTabs(_ ids: Set<UUID>) {
        for id in Array(views.keys) where !ids.contains(id) {
            if let browser = views[id] as? SupportingBrowserView { browser.dispose() }
            if let artifact = views[id] as? SupportingArtifactView { artifact.dispose() }
            views.removeValue(forKey: id)?.removeFromSuperview()
        }
    }
    func focusAddress(in window: NSWindow) -> Bool {
        for case let browser as SupportingBrowserView in views.values where browser.containsFocus(in: window) {
            browser.focusAddress(); return true
        }
        return false
    }
    static func chooseArtifact(in window: NSWindow, selected: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Open a local artifact preview"
        panel.beginSheetModal(for: window) { result in
            if result == .OK, let path = panel.url?.path { selected(path) }
        }
    }
}

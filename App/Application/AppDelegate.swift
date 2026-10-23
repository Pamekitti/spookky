import AppKit
import SpookkyCore
import SpookkyWorkspace
import SpookkyPersistence

@main @MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var workspace: WorkspaceWindowController?
    static func main() {
        if CommandLine.arguments.contains(where: ApplicationArguments.isHarnessFlag) {
            fputs("Native diagnostics require the SpookkyHarness target. Run python3 scripts/test.py native.\n", stderr)
            exit(64)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let paths = AppPaths(bundleID: Bundle.main.bundleIdentifier, home: FileManager.default.homeDirectoryForCurrentUser, userID: getuid())
        if paths.production && !InstallationLocation.canRun { InstallationLocation.showGuidance(); NSApp.terminate(nil); return }
        Task {
            do {
                workspace = try await ApplicationBootstrap.workspace(paths: paths)
                workspace?.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                let alert = ChromeAlert()
                alert.messageText = "Spookky could not restore workspaces"
                alert.informativeText = error.localizedDescription + "\nYour database and running sessions were preserved.\nDatabase folder: " + paths.data.path
                alert.addButton(withTitle: "Quit"); alert.runModal(); NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { workspace?.prepareToQuit() ?? .terminateNow }
    func applicationDidBecomeActive(_ notification: Notification) { workspace?.setFocus(true) }
    func applicationDidResignActive(_ notification: Notification) { workspace?.setFocus(false) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { workspace?.reopen(); return true }
}

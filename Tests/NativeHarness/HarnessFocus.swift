import AppKit
import SpookkyCore

@MainActor enum HarnessFocus {
    static func activate(_ window: NSWindow) async throws {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        if NSApp.isActive && window.isKeyWindow { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        let running = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        window.makeKeyAndOrderFront(nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var attempts = 0
        while !NSApp.isActive || !window.isKeyWindow {
            guard ContinuousClock.now < deadline else { throw LaunchError.invalid("Harness window could not acquire foreground focus: current=\(getpid()), opened=\(running.processIdentifier), frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"), visible=\(window.isVisible), key=\(window.isKeyWindow).") }
            attempts += 1
            if attempts.isMultiple(of: 25) {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                window.makeKeyAndOrderFront(nil)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

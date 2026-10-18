import AppKit
import WebKit
import PDFKit
import SpookkyCore
import SpookkyRuntime

@MainActor enum SupportingPreviewFixture {
    static func recordRestoration(host: BrowserArtifactContentHost, state: WorkspaceState, root: URL) throws {
        guard CommandLine.arguments.contains("--workspace-benchmark-browser-restored"),
              root.path.hasPrefix("/tmp/spookky-m1-browser-"), ProcessInfo.processInfo.environment["SPOOKKY_M1_DATA"] != nil else { return }
        let browsers = state.workspaces.flatMap { $0.support?.tabs ?? [] }.filter { if case .browser = $0.target { return true }; return false }
        try PrivateFiles.write(["ten_restored_browser_descriptors": browsers.count == 10,
                               "cold_restore_zero_webviews": host.browserCount == 0,
                               "cold_restore_zero_materialized_previews": host.materializedCount == 0], to: root.appendingPathComponent("browser-restored-checks.json"))
    }
    static func run(window: NSWindow, host: BrowserArtifactContentHost,
                    state: () -> WorkspaceState, mutate: ((inout WorkspaceState) -> Void) -> Void,
                    command: (NSEvent) -> Bool, openTerminal: () -> Void, terminal: () -> TerminalHostView?,
                    runtime: any SessionRuntime, root: URL) async throws {
        guard let fixtureURL = ProcessInfo.processInfo.environment["SPOOKKY_BROWSER_FIXTURE_URL"],
              let original = state().selectedWorkspaceID else { throw LaunchError.invalid("Browser fixture URL or workspace missing") }
        var checks: [String: Bool] = [:]
        func wait(_ message: String, until condition: () -> Bool) async throws {
            for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
            throw LaunchError.invalid(message)
        }
        func key(_ text: String, code: UInt16) throws -> NSEvent {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else { throw LaunchError.invalid("Browser fixture key unavailable") }
            return event
        }
        func browser(_ id: UUID) -> SupportingBrowserView? {
            guard let workspace = state().selected, let tab = workspace.support?.tabs.first(where: { $0.id == id }) else { return nil }
            return host.view(for: tab, workspace: workspace, update: { _, _ in }) as? SupportingBrowserView
        }
        func js(_ browser: SupportingBrowserView, _ script: String) async throws -> String {
            let value = try await browser.webView.evaluateJavaScript(script)
            return value as? String ?? String(describing: value ?? "nil")
        }
        func snapshot(_ name: String, width: CGFloat, height: CGFloat, appearance: WorkspaceAppearance) async throws {
            mutate { $0.appearance = appearance }
            window.setContentSize(NSSize(width: width, height: height)); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            if let view = state().selected?.support?.selected, let browserView = browser(view.id) {
                let image = try await browserView.webView.takeSnapshot(configuration: nil)
                if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                    try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(name + "-page.png"))
                }
            }
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait("Browser fixture window did not activate") { window.isKeyWindow }
        checks["startup_zero_webviews"] = host.browserCount == 0
        var ids: [UUID] = []
        mutate { value in
            for _ in 0..<10 { if let id = value.openSupport(.browser(url: fixtureURL), title: "Saved browser") { ids.append(id) } }
            value.setSupportingLayout(.collapsed)
        }
        checks["ten_saved_descriptors_zero_webviews"] = host.browserCount == 0 && ids.count == 10
        // Landing browsing above starts no agent. The remaining checks need an ordinary primary shell.
        mutate { $0.promoteLanding(original); $0.selectSupport(ids[0]); $0.setSupportingLayout(.split) }
        guard let first = browser(ids[0]) else { throw LaunchError.invalid("Browser host did not materialize") }
        try await wait("Localhost page failed") { first.webView.title == "Fixture one" && !first.webView.isLoading }
        checks["selected_only_one_webview"] = host.browserCount == 1
        checks["localhost_real_title_url"] = first.webView.url?.absoluteString == fixtureURL
        checks["cmd_t_without_agent"] = command(try key("t", code: 17)) && state().workspaces.flatMap(\.tabs).allSatisfy { $0.binding == nil }
        let blankID = state().selected!.support!.selectedTabID!
        weak var blankReference: SupportingBrowserView?
        do {
            guard let blank = browser(blankID) else { throw LaunchError.invalid("Blank browser missing") }
            blankReference = blank
            checks["new_tab_address_focus"] = blank.address.currentEditor() != nil
        }
        mutate { $0.closeSupport(blankID); $0.selectSupport(ids[0]) }
        try await wait("Closed browser did not release") { blankReference == nil }
        checks["closed_browser_deallocated"] = true
        let initial = "a b ไทย <script>literal</script>"
        _ = try await js(first, "document.querySelector('input').value = 'a b ไทย <script>literal</script>'; document.querySelector('input').focus(); 'ok'")
        let focused = window.firstResponder
        _ = try await js(first, "document.title = 'Live title ไทย'; 'ok'")
        try await wait("Title did not persist") { state().selected?.support?.selected?.title == "Live title ไทย" }
        checks["title_update_preserves_form_focus"] = window.firstResponder === focused
        mutate { $0.selectSupport(ids[1]) }
        mutate { $0.selectSupport(ids[0]) }
        checks["same_view_after_tab_switch"] = browser(ids[0]) === first
        checks["unsent_form_survives_tab_switch"] = try await js(first, "document.querySelector('input').value") == initial
        mutate { $0.newWorkspace(directory: root.path) }
        mutate { $0.selectWorkspace(original) }
        checks["unsent_form_survives_conversation_switch"] = try await js(first, "document.querySelector('input').value") == initial
        mutate { $0.setSupportingLayout(.collapsed) }
        mutate { $0.setSupportingLayout(.fullWidth) }
        mutate { $0.setSupportingLayout(.split) }
        checks["unsent_form_survives_layouts"] = try await js(first, "document.querySelector('input').value") == initial
        window.makeFirstResponder(first.webView)
        checks["cmd_l_focuses_address"] = command(try key("l", code: 37)) && first.address.currentEditor() != nil && state().selected?.support?.layout == .split
        first.navigate(fixtureURL.replacingOccurrences(of: "index.html", with: "second.html"))
        try await wait("Address navigation failed") { first.webView.title == "Fixture two" && first.webView.canGoBack && !first.webView.isLoading }
        checks["address_navigation"] = true
        first.webView.goBack()
        try await wait("Back failed") { first.webView.title == "Live title ไทย" || first.webView.title == "Fixture one" }
        first.webView.goForward()
        try await wait("Forward failed") { first.webView.title == "Fixture two" && !first.webView.isLoading }
        checks["back_forward"] = true
        _ = try await js(first, "document.title = 'Before reload'; 'ok'")
        first.reloadOrStop()
        try await wait("Reload failed") { first.webView.title == "Fixture two" && !first.webView.isLoading }
        checks["reload"] = true
        first.navigate("mailto:test@example.invalid")
        checks["unsupported_scheme_explicit_external"] = first.webView.url?.lastPathComponent == "second.html"
        first.navigate(ProcessInfo.processInfo.environment["SPOOKKY_BROWSER_UNAVAILABLE_URL"] ?? "http://127.0.0.1:65534/unavailable")
        try await wait("Browser failure notice missing") {
            first.subviews.contains { ($0 as? NSTextField)?.stringValue.hasPrefix("Could not load page:") == true }
        }
        checks["browser_failure_visible"] = true
        first.navigate(fixtureURL.replacingOccurrences(of: "index.html", with: "slow.html"))
        try await wait("Browser never started loading") { first.navigationStarted && first.webView.isLoading }
        first.reloadOrStop()
        do { try await wait("Stop did not stop loading") { !first.webView.isLoading } }
        catch {
            let fields = first.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " | ")
            throw LaunchError.invalid("Stop did not stop loading. Browser fields: " + fields)
        }
        checks["stop_loading"] = true
        first.navigate(fixtureURL)
        try await wait("Return page failed") { first.webView.title == "Fixture one" && !first.webView.isLoading }
        try await snapshot("browser-dark-wide", width: 1440, height: 900, appearance: .dark)
        try await snapshot("browser-light-narrow", width: 650, height: 450, appearance: .light)
        let artifactRoot = root.appendingPathComponent("artifacts ไทย spaces")
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        let markdown = artifactRoot.appendingPathComponent("notes $(literal).md")
        try Data("# Local Markdown\n\n<script>literal</script>\nไทย and spaces".utf8).write(to: markdown)
        let html = artifactRoot.appendingPathComponent("local page.html")
        try Data("<html><head><title>Local HTML</title></head><body><h1>Local artifact ไทย</h1><input value='unsent local'><button onclick=\"document.querySelector('output').textContent=++window.counter\">Count</button><output>0</output><script>window.counter=0</script></body></html>".utf8).write(to: html)
        let image = NSImage(size: NSSize(width: 96, height: 96)); image.lockFocus(); NSColor.systemTeal.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 96, height: 96)).fill(); image.unlockFocus()
        let png = artifactRoot.appendingPathComponent("image ไทย.png")
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: png)
        let pdf = PDFDocument(); pdf.insert(PDFPage(image: image)!, at: 0)
        let pdfURL = artifactRoot.appendingPathComponent("sample.pdf"); pdf.write(to: pdfURL)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        var htmlTabID: UUID?
        var htmlView: WKWebView?
        for (url, type) in [(markdown, "markdown"), (html, "html"), (png, "image"), (pdfURL, "pdf")] {
            var id: UUID?
            mutate { id = $0.openSupport(.artifact(path: url.path), title: url.lastPathComponent) }
            let workspace = state().selected!, tab = workspace.support!.selected!
            guard id == tab.id, let view = host.view(for: tab, workspace: workspace, update: { _, _ in }) else { throw LaunchError.invalid("Artifact not installed") }
            try await wait("Artifact failed: " + type) {
                let all = descendants(view)
                switch type {
                case "markdown": return all.contains { ($0 as? NSTextView)?.string.contains("<script>literal</script>") == true }
                case "html": return all.contains { ($0 as? WKWebView)?.title == "Local HTML" }
                case "image": return all.contains { ($0 as? NSImageView)?.image != nil }
                default: return all.contains { ($0 as? PDFView)?.document?.pageCount == 1 }
                }
            }
            checks["local_" + type + "_rendered"] = true
            if type == "html" {
                htmlTabID = tab.id; htmlView = descendants(view).compactMap { $0 as? WKWebView }.first
                _ = try await htmlView?.evaluateJavaScript("document.querySelector('button').click(); document.querySelector('input').value='artifact unsent'")
                checks["html_inline_counter"] = String(describing: try await htmlView?.evaluateJavaScript("document.querySelector('output').textContent") ?? "") == "1"
                let endpoint = String(data: try JSONEncoder().encode(fixtureURL + "?artifact-network-probe=1"), encoding: .utf8)!
                _ = try await htmlView?.evaluateJavaScript("fetch(" + endpoint + ", {mode:'no-cors'}).then(()=>window.networkAllowed=true).catch(()=>window.networkAllowed=false); 'ok'")
            }
        }
        for (name, contents, message) in [("missing.txt", Data(), "unavailable"), ("large.txt", Data(repeating: 32, count: 2 * 1024 * 1024 + 1), "size limit"), ("unknown.bin", Data([1, 2]), "format")] {
            let url = artifactRoot.appendingPathComponent(name)
            if name != "missing.txt" { try contents.write(to: url) }
            mutate { $0.openSupport(.artifact(path: url.path), title: name) }
            let workspace = state().selected!, tab = workspace.support!.selected!
            let view = host.view(for: tab, workspace: workspace, update: { _, _ in })!
            try await wait("Artifact error state missing: " + name) { descendants(view).contains { ($0 as? NSTextField)?.stringValue.contains(message) == true } }
            checks["artifact_" + name + "_state"] = true
        }
        if let htmlTabID, let htmlView {
            mutate { $0.selectSupport(htmlTabID) }
            checks["html_counter_survives_switch"] = (try await htmlView.evaluateJavaScript("document.querySelector('output').textContent") as? String) == "1"
            checks["html_form_survives_switch"] = (try await htmlView.evaluateJavaScript("document.querySelector('input').value") as? String) == "artifact unsent"
            checks["html_network_blocked"] = (try await htmlView.evaluateJavaScript("window.networkAllowed") as? Bool) == false
        }
        checks["no_primary_runtime_started"] = state().workspaces.flatMap(\.tabs).allSatisfy { $0.binding == nil }
        mutate { $0.selectSupport(ids[0]); $0.setSupportingLayout(.split) }
        openTerminal()
        try await wait("Primary shell did not launch") { terminal() != nil && state().selected?.primaryTerminal?.status == .running }
        guard let surface = terminal(), let binding = state().selected?.primaryTerminal?.binding else { throw LaunchError.invalid("Primary shell unavailable") }
        try await wait("Primary prompt not ready") { surface.visibleText().trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%") }
        let processBefore = try await runtime.inspect(binding)?.processID
        window.makeFirstResponder(surface)
        surface.insertText("SPOOKKY_BROWSER_UNSENT", replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = try await js(first, "document.title='Terminal focus retained'; 'ok'")
        try await wait("Primary title callback missing") { state().selected?.support?.selected?.title == "Terminal focus retained" }
        checks["browser_title_preserves_terminal_focus"] = window.firstResponder === surface
        let beforeClose = host.browserCount
        mutate { $0.closeSupport(ids[0], workspaceID: original) }
        checks["closed_browser_removed_from_cache"] = host.browserCount == beforeClose - 1
        checks["browser_close_preserves_primary_process"] = try await runtime.inspect(binding)?.processID == processBefore
        checks["browser_close_preserves_terminal_draft"] = surface.visibleText().contains("SPOOKKY_BROWSER_UNSENT")
        checks["all_live_views_retained"] = host.materializedCount >= 8
        try PrivateFiles.write(checks, to: root.appendingPathComponent("browser-checks.json"))
        if checks.values.contains(false) { throw LaunchError.invalid("Browser fixture failed: " + checks.filter { !$0.value }.map(\.key).joined(separator: ", ")) }
        mutate {
            $0.openSupport(.browser(url: fixtureURL), title: "Saved restore descriptor", workspaceID: original)
            $0.selectSupport(ids[1], workspaceID: original)
        }
    }
}

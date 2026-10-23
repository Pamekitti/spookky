// Verify prototype navigation and narrow layouts without opening a browser window.
import AppKit
import XCTest
import WebKit

@MainActor final class PrototypeCheck: NSObject, WKScriptMessageHandler {
    let web: WKWebView
    let window: NSWindow
    var frame: WKFrameInfo?
    var skipped: [String: String] = [:]
    var checks: [String: Bool] = [:]
    let destination: URL
    init(source: URL, destination: URL) throws {
        self.destination = destination
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = web
        config.userContentController.add(self, name: "spookkyCheck")
        let ready = "if(document.getElementById('spookky-app'))window.webkit.messageHandlers.spookkyCheck.postMessage({ready:true});"
        config.userContentController.addUserScript(WKUserScript(source: ready, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        web.loadHTMLString(try String(contentsOf: source, encoding: .utf8), baseURL: source.deletingLastPathComponent())
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        frame = message.frameInfo
    }
    func js(_ source: String) async throws -> Any? {
        guard let frame else { throw NSError(domain: "PrototypeCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Prototype frame did not load"] ) }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            web.evaluateJavaScript(source, in: frame, in: .page) { result in
                continuation.resume(with: result.map { Optional($0) })
            }
        }
    }
    func check(_ name: String, _ expression: String, requiresFocus: Bool = false) async throws {
        if requiresFocus, (try await js("document.hasFocus()") as? Bool) != true {
            skipped[name] = "Offscreen WebKit has no active OS keyboard window"
            print(name + ": skipped")
            return
        }
        let value = try await js(expression)
        checks[name] = (value as? Bool) == true
        print(name + ": " + String(checks[name]!))
    }
    func save(_ image: NSImage, suffix: String) throws {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PrototypeCheck", code: 3, userInfo: [NSLocalizedDescriptionKey: "Snapshot did not render"])
        }
        try png.write(to: destination.deletingLastPathComponent().appendingPathComponent("prototype-" + suffix + ".png"))
    }
    func run() async throws {
        for _ in 0..<1200 {
            if frame != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard frame != nil else { throw NSError(domain: "PrototypeCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Prototype frame did not load"] ) }
        for _ in 0..<200 {
            if (try await js("!!document.querySelector('[data-action=\"close-primary\"] svg')") as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await check("icon_library_loaded", "!!document.querySelector('[data-action=\"close-primary\"] svg')")
        print("viewport: " + String(describing: try await js("({width:innerWidth,height:innerHeight,rows:document.querySelectorAll('.workspace-row').length})")))
        try await check("desktop_project_rows", "document.querySelectorAll('.workspace-row').length===2")
        _ = try await js("window.qaHome=document.querySelector('[aria-current=page]').dataset.id;document.querySelector('[data-action=\"tool\"][data-tool=\"codex\"]').click();const input=document.querySelector('.composer-input');input.value='Keep this draft through project navigation';input.dispatchEvent(new Event('input',{bubbles:true}));")
        _ = try await js("window.qaNames=Array.from(document.querySelectorAll('.workspace-row')).map(n=>n.querySelector('button').dataset.id); document.querySelector('[data-action=\"project-nav\"][data-id=\"p-n\"]').focus(); document.querySelector('[data-action=\"project-nav\"][data-id=\"p-n\"]').click();")
        try await check("project_click_collapses", "document.querySelector('[data-action=\"project-nav\"][data-id=\"p-n\"]').closest('section').querySelectorAll('.workspace-row').length===0")
        try await check("project_keyboard_focus_retained", "document.activeElement.dataset.action==='project-nav' && document.activeElement.dataset.id==='p-n'")
        _ = try await js("document.querySelector('[data-action=\"project-nav\"][data-id=\"p-n\"]').click()")
        try await check("project_click_expands_without_creation", "JSON.stringify(Array.from(document.querySelectorAll('.workspace-row')).map(n=>n.querySelector('button').dataset.id))===JSON.stringify(window.qaNames)")
        try await Task.sleep(for: .milliseconds(100))
        _ = try await js("document.querySelector('[data-action=\"search\"]')?.focus(); document.activeElement.blur();")
        try await check("workspace_close_hidden_at_rest", "Array.from(document.querySelectorAll('[data-action=\"close-workspace\"]')).every(n=>getComputedStyle(n).visibility==='hidden')")
        try await check("tab_close_hidden_at_rest", "getComputedStyle(document.querySelector('[data-action=\"close-primary\"]')).visibility==='hidden'")
        _ = try await js("document.querySelector('.session-tab').focus()")
        try await check("keyboard_reveals_tab_close", "getComputedStyle(document.querySelector('[data-action=\"close-primary\"]')).visibility==='visible'", requiresFocus: true)
        try await check("compact_tab_close_target", "document.querySelector('[data-action=\"close-primary\"]').getBoundingClientRect().height===24")
        _ = try await js("window.qaTitle=document.querySelector('.workspace-name'); window.qaRow=window.qaTitle.closest('.workspace-row');document.activeElement.blur();")
        try await check("compact_close_glyph", "getComputedStyle(document.querySelector('[data-action=\"close-primary\"] svg')).width==='12px'")
        try await check("compact_hover_fill", "getComputedStyle(document.querySelector('[data-action=\"close-primary\"]'),'::before').width==='20px' && getComputedStyle(document.querySelector('[data-action=\"close-primary\"]'),'::before').height==='20px'")
        try await check("bounded_title_duration", "parseFloat(qaTitle.style.getPropertyValue('--duration'))>=.5 && parseFloat(qaTitle.style.getPropertyValue('--duration'))<=6")
        try await check("long_title_fades", "qaTitle.dataset.overflow==='true' && getComputedStyle(qaTitle).maskImage.includes('linear-gradient')")
        _ = try await js("qaRow.querySelector('button').focus()")
        try await check("keyboard_reveals_workspace_close", "getComputedStyle(qaRow.querySelector('[data-action=\"close-workspace\"]')).visibility==='visible'", requiresFocus: true)
        try await Task.sleep(for: .milliseconds(700))
        try await check("long_title_moves_on_focus", "getComputedStyle(qaTitle.firstElementChild).transform!=='none' && !getComputedStyle(qaTitle.firstElementChild).transform.includes(', 0, 0)')", requiresFocus: true)
        _ = try await js("document.activeElement.blur()")
        try await Task.sleep(for: .milliseconds(300))
        try await check("long_title_returns_to_start", "getComputedStyle(qaTitle.firstElementChild).transform==='none' || getComputedStyle(qaTitle.firstElementChild).transform.includes(', 0, 0)')", requiresFocus: true)
        let desktop = try await web.takeSnapshot(configuration: nil)
        try save(desktop, suffix: "desktop")
        _ = try await js("document.querySelector('[data-action=\"new-project-workspace\"][data-id=\"p-n\"]').click()")
        try await check("separate_plus_creates_workspace", "document.querySelectorAll('.workspace-row').length===3 && document.querySelector('[data-action=\"project-nav\"][data-id=\"p-n\"]').closest('section').querySelectorAll('.workspace-row').length===2")
        _ = try await js("document.querySelector('[data-action=\"project-nav\"][data-id=\"\"]').click()")
        try await check("home_navigation_keeps_workspace_count", "document.querySelectorAll('.workspace-row').length===3 && document.querySelector('[aria-current=page]').dataset.id===qaHome")
        try await check("prompt_survives_project_navigation", "document.querySelector('.composer-input').value==='Keep this draft through project navigation'")
        for width in [390,320] {
            window.setContentSize(NSSize(width: width, height: 900))
            web.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            try await Task.sleep(for: .milliseconds(200))
            try await check("narrow_\(width)_fits", "document.getElementById('spookky-app').scrollWidth<=document.getElementById('spookky-app').clientWidth+1")
            try await check("narrow_\(width)_sidebar_collapses", "document.getElementById('spookky-app').classList.contains('nav-hidden')")
            let image = try await web.takeSnapshot(configuration: nil)
            try save(image, suffix: String(width))
        }
        checks["offscreen_window_stays_hidden"] = !window.isVisible
        let report: [String: Any] = ["checks":checks, "skipped":skipped, "visible_window":window.isVisible, "failed": checks.filter { !$0.value }.keys.sorted(), "boundary":"Offscreen WebKit DOM, CSS, and snapshots. No browser window or physical pointer input."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: destination)
        web.stopLoading(); web.configuration.userContentController.removeScriptMessageHandler(forName: "spookkyCheck")
        if checks.values.contains(false) { throw NSError(domain: "PrototypeCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Prototype checks failed"] ) }
    }
}
@MainActor final class PrototypeTests: XCTestCase {
    func testPrototypeNavigationAndNarrowLayouts() async throws {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["SPOOKKY_SOURCE_ROOT"])
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["SPOOKKY_TEST_EVIDENCE"])
        let destination = URL(fileURLWithPath: output).appendingPathComponent("prototype-webkit.json")
        let runner = try PrototypeCheck(source: URL(fileURLWithPath: root).appendingPathComponent("prototype/index.html"), destination: destination)
        try await runner.run()
        XCTAssertFalse(runner.checks.isEmpty)
        for (name, passed) in runner.checks { XCTAssertTrue(passed, name) }
    }
}

import AppKit
import XCTest
import SpookkyCore
import SpookkyRuntime
import SpookkyWorkspace
@testable import SpookkyHarness

@MainActor final class NativeScenarioTests: XCTestCase {
    private func run(flags: [String] = [], reports: [String] = [], _ scenario: (WorkspaceWindowController, URL) async throws -> Void) async throws {
        ApplicationArguments.override = ["SpookkyHarness", "--workspace-benchmark-count", "0"] + flags
        defer { ApplicationArguments.override = nil }
        let parent = ProcessInfo.processInfo.environment["SPOOKKY_M1_ROOT"] ?? "/tmp/spookky-m1-xctest-" + UUID().uuidString
        let root = URL(fileURLWithPath: parent).appendingPathComponent("case-" + UUID().uuidString)
        try PrivateFiles.directory(root)
        let paths = AppPaths(bundleID: "dev.spookky.harness", home: root, userID: getuid(), environment: ["SPOOKKY_M1_ROOT": root.path, "SPOOKKY_M1_DATA": root.appendingPathComponent("metadata").path])
        let store = try await ApplicationBootstrap.store(paths: paths)
        let controller = try await ApplicationBootstrap.workspace(paths: paths, initialStore: store, resolver: WorkspaceBenchmarkResolver(), backgroundFixture: !flags.contains("--workspace-benchmark-front"))
        (NSApp.delegate as? HarnessAppDelegate)?.hostWorkspace(controller)
        defer {
            if let destination = ProcessInfo.processInfo.environment["SPOOKKY_TEST_EVIDENCE"] {
                let directory = URL(fileURLWithPath: destination).appendingPathComponent(root.lastPathComponent)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for file in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where ["json", "png", "log"].contains(file.pathExtension) {
                    try? FileManager.default.copyItem(at: file, to: directory.appendingPathComponent(file.lastPathComponent))
                }
            }
            controller.window.orderOut(nil)
            // The runner releases private servers and files after this test host exits.
        }
        do {
        if flags.contains("--workspace-benchmark-front") {
            try await HarnessFocus.activate(controller.window)
        }
            try await scenario(controller, root)
            if !reports.isEmpty { try validateReports(root, requiredReports: reports) }
        } catch {
            try? PrivateFiles.write(["error": String(reflecting: error), "active": String(NSApp.isActive), "policy": String(NSApp.activationPolicy().rawValue), "key": String(controller.window.isKeyWindow), "allowsFocus": String(controller.window.acceptsUserFocus), "flags": flags.joined(separator: " "), "keyWindow": String(describing: NSApp.keyWindow)], to: root.appendingPathComponent("native-failure.json"))
            throw error
        }
    }
    private func validateReports(_ root: URL, requiredReports: [String]) throws {
        let contractURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "native-assertions", withExtension: "json"))
        let contracts = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: contractURL))
        XCTAssertFalse(requiredReports.isEmpty)
        for name in requiredReports {
            let file = root.appendingPathComponent(name)
            let required = try XCTUnwrap(contracts[name])
            let checks = try FixtureAssertions.decode(Data(contentsOf: file), required: required)
            try PrivateFiles.write(["missing": Array(Set(required).subtracting(checks.keys)), "failed": checks.filter { !$0.value }.map(\.key)], to: root.appendingPathComponent("assertion-verdict.json"))
            XCTAssertFalse(required.isEmpty)
            XCTAssertTrue(Set(required).isSubset(of: checks.keys), "Missing required assertions: \(Set(required).subtracting(checks.keys))")
            for (name, passed) in checks { XCTAssertTrue(passed, "\(file.lastPathComponent): \(name)") }
            // The runner preserves the original report beside the xcresult bundle.
        }
    }
    private func fixture(_ flag: String, count: Int = 0) async throws {
        let reports = ["--workspace-benchmark-composer": "composer-checks.json", "--workspace-benchmark-prompt-images": "prompt-image-checks.json",
            "--workspace-benchmark-project-association": "project-association-checks.json", "--workspace-benchmark-identity": "identity-checks.json",
            "--workspace-benchmark-sidebar": "sidebar-checks.json", "--workspace-benchmark-history": "history-checks.json",
            "--workspace-benchmark-close": "close-checks.json", "--workspace-benchmark-races": "surface-races.json", "--workspace-benchmark-selection": "selection-checks.json"]
        let report = try XCTUnwrap(reports[flag])
        try await run(flags: [flag, "--workspace-benchmark-front"], reports: [report]) { controller, root in
            ApplicationArguments.override = ["SpookkyHarness", "--workspace-benchmark-count", String(count), flag, "--workspace-benchmark-front"]
            try await controller.benchmark(count: count, root: root, timing: false)

        }
    }
    func testComposer() async throws { try await fixture("--workspace-benchmark-composer") }
    func testImages() async throws { try await fixture("--workspace-benchmark-prompt-images") }
    func testProjectAssociation() async throws { try await fixture("--workspace-benchmark-project-association") }
    func testIdentity() async throws { try await fixture("--workspace-benchmark-identity") }
    func testSidebar() async throws { try await fixture("--workspace-benchmark-sidebar") }
    func testHistory() async throws { try await fixture("--workspace-benchmark-history") }
    func testClose() async throws { try await fixture("--workspace-benchmark-close") }
    func testRaces() async throws { try await fixture("--workspace-benchmark-races", count: 1) }
    func testSelection() async throws { try await fixture("--workspace-benchmark-selection", count: 1) }
    func testDisplay() async throws {
        try await run(flags: ["--workspace-benchmark-sidebar", "--workspace-benchmark-display", "--workspace-benchmark-front"], reports: ["sidebar-checks.json", "display-checks.json"]) { controller, root in
            ApplicationArguments.override = ["SpookkyHarness", "--workspace-benchmark-count", "0", "--workspace-benchmark-sidebar", "--workspace-benchmark-display", "--workspace-benchmark-front"]
            try await controller.checkSidebar(root: root)
        }
    }
    func testReference() async throws {
        try await run(flags: ["--workspace-benchmark-front"], reports: ["sidebar-reference-checks.json"]) { controller, root in
            try await SidebarReferenceFixture.run(window: controller.window, root: root, setAppearance: { appearance in controller.store.update { $0.appearance = appearance } })
        }
    }
    func testSmoke() async throws {
        try await run { controller, root in
            let first = try XCTUnwrap(controller.store.state.primaryTerminalID)
            controller.store.update { $0.editDraft(first, tool: .codex, prompt: "Retained native draft") }
            controller.openTerminal(from: first)
            for _ in 0..<200 {
                if controller.store.state.selectedTab?.binding != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let live = try XCTUnwrap(controller.store.state.selectedTab)
            let binding = try XCTUnwrap(live.binding)
            if let task = controller.renderTask { await task.value }
            let surface = try XCTUnwrap(controller.surfaces.view(live.id))
            XCTAssertNotNil(surface.surface, "The real shell must be attached to Ghostty")
            let promptDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while surface.visibleText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ContinuousClock.now < promptDeadline { try await Task.sleep(for: .milliseconds(20)) }
            surface.insertText("printf '%s%s\\n' 'SPOOKKY_' 'NATIVE_SMOKE_READY'", replacementRange: NSRange(location: NSNotFound, length: 0))
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: controller.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            surface.keyDown(with: enter)
            let outputDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !surface.visibleText().contains("SPOOKKY_NATIVE_SMOKE_READY") && ContinuousClock.now < outputDeadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(surface.visibleText().contains("SPOOKKY_NATIVE_SMOKE_READY"), "Shell input must return through the attached terminal")
            let before = try await controller.launches.runtime.inspect(binding)
            XCTAssertNotNil(before?.processID)
            controller.selectTab(first)
            XCTAssertEqual(controller.store.state.tab(first)?.draft.prompt, "Retained native draft")
            controller.selectTab(live.id)
            await controller.launches.reconcile(live.id)
            controller.window.close()
            controller.reopen()
            let after = try await controller.launches.runtime.inspect(binding)
            XCTAssertEqual(before?.processID, after?.processID)
            XCTAssertEqual(controller.store.state.tab(first)?.draft.prompt, "Retained native draft")
        }
    }
}

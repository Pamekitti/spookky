import Foundation
import SpookkyCore
import SpookkyWorkspace
import SpookkyRuntime

enum WorkspaceBenchmarkOptions {
    static func cycleCount(arguments: [String] = CommandLine.arguments) throws -> Int {
        let index = arguments.firstIndex(of: "--workspace-benchmark-cycle-count")
        let count = index.flatMap { arguments.indices.contains($0 + 1) ? Int(arguments[$0 + 1]) : nil } ?? 110
        guard (0...110).contains(count) else { throw LaunchError.invalid("Invalid fixture cycle count") }
        return count
    }
}

struct WorkspaceBenchmarkResolver: ExecutableResolver {
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        guard tool == .shell else { throw LaunchError.invalid("The workspace benchmark supports shells only.") }
        return try LaunchSpec(tool: .shell, executable: "/bin/zsh", arguments: ["-f"], directory: directory,
                              environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PS1": "%% ", "PROMPT": "%% "])
    }
}

actor WorkspaceViewportFixtureRuntime: SessionViewportRuntime {
    private let base: any SessionViewportRuntime
    private var viewportCountdown: Int?
    private var holdRestore = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isHeld: Bool { continuation != nil }
    init(_ base: any SessionViewportRuntime) { self.base = base }
    func holdViewport(after calls: Int) { viewportCountdown = calls }
    func holdRestoration() { holdRestore = true }
    func resume() { continuation?.resume(); continuation = nil }
    func create(_ spec: LaunchSpec) async throws -> SessionBinding { try await base.create(spec) }
    func inspect(_ binding: SessionBinding) async throws -> SessionObservation? { try await base.inspect(binding) }
    func list() async throws -> [SessionBinding] { try await base.list() }
    func attachmentArguments(_ binding: SessionBinding) async throws -> [String] { try await base.attachmentArguments(binding) }
    func terminate(_ binding: SessionBinding) async throws { try await base.terminate(binding) }
    func viewport(_ binding: SessionBinding) async throws -> SessionViewport? {
        let result = try await base.viewport(binding)
        if let remaining = viewportCountdown {
            viewportCountdown = remaining > 1 ? remaining - 1 : nil
            if remaining == 1 { await withCheckedContinuation { continuation = $0 } }
        }
        return result
    }
    func restoreViewport(_ viewport: SessionViewport, binding: SessionBinding, columns: Int, rows: Int) async throws {
        try await base.restoreViewport(viewport, binding: binding, columns: columns, rows: rows)
        if holdRestore {
            holdRestore = false
            await withCheckedContinuation { continuation = $0 }
        }
    }
}

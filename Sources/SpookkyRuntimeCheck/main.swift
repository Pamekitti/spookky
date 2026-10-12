import Foundation
import SpookkyCore
import SpookkyRuntime

@main struct RuntimeCheck {
    static func main() async throws {
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("spookky-launch").path
        let root = URL(fileURLWithPath: "/tmp/spookky-check-" + UUID().uuidString.prefix(8))
        let runtime = try TmuxRuntime(executable: PackagedRuntime.tmux(), helper: helper, root: root)
        let cycles = CommandLine.arguments.contains("--cycles") ? 100 : 1
        let start = Date()
        for _ in 0..<cycles {
            let spec = try LaunchSpec(tool: .shell, executable: "/bin/cat", directory: "/tmp")
            let binding = try await runtime.create(spec)
            let first = try await runtime.inspect(binding)
            let again = try await runtime.create(spec)
            guard first?.dead == false, again.id == binding.id else { throw LaunchError.command("Runtime check failed.") }
            _ = try await runtime.attachmentArguments(binding)
            try await runtime.terminate(binding)
        }
        guard try await runtime.list().isEmpty else { throw LaunchError.command("Runtime leaked a session.") }
        try FileManager.default.removeItem(at: root)
        print("\(cycles) private runtime create/inspect/retry/attachment/cleanup cycles passed in \(Date().timeIntervalSince(start)) seconds.")
    }
}

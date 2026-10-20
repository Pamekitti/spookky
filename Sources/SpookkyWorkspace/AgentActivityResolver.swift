import Foundation
import SpookkyCore
import SpookkyRuntime

public struct AgentActivityResolver: ExecutableResolver {
    private let base: any ExecutableResolver
    private let root: URL
    private let helper: String
    public init(base: any ExecutableResolver, root: URL, helper: String) {
        self.base = base; self.root = root; self.helper = helper
    }
    public func resolveFresh(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try await resolveFresh(tool, directory: directory, prompt: prompt, images: [])
    }
    public func resolveFresh(_ tool: SessionTool, directory: String, prompt: String?, images: [String]) async throws -> LaunchSpec {
        try await resolveFresh(tool, directory: directory, prompt: prompt, images: images, model: AgentModelSelection())
    }
    public func resolveFresh(_ tool: SessionTool, directory: String, prompt: String?, images: [String], model: AgentModelSelection) async throws -> LaunchSpec {
        let resolved = try await base.resolve(tool, directory: directory, prompt: prompt)
        let original = try await resolved.attachingPromptImages(images).selectingModel(model)
        let root = root, helper = helper
        return await Task.detached {
            var spec = original
            var environment = ProcessInfo.processInfo.environment.merging(original.environment) { _, value in value }
            if tool == .claude, let help = try? ProcessRunner.run(original.executable, ["--help"], timeout: 3, outputLimit: 65_536, environment: environment),
               help.status == 0, ProviderContinuationCapabilities.advertises("--session-id", in: help.output) {
                let id = UUID().uuidString.lowercased()
                environment = original.environment; environment["SPOOKKY_PROVIDER_SESSION_ID"] = id
                spec = (try? LaunchSpec(operationID: original.operationID, tool: tool, executable: original.executable,
                    arguments: ["--session-id", id] + original.arguments, directory: directory, environment: environment)) ?? original
            } else if tool == .codex,
                      let command = try? CodexHistoryReader.notificationCommand(executable: original.executable, environment: environment, directory: directory),
                      let forward = try? JSONEncoder().encode(command) {
                let context = root.appendingPathComponent("agent-terminal-" + original.operationID.uuidString + ".json").path
                let callback = [helper, "--agent-identity", context, forward.base64EncodedString()]
                if let json = try? JSONSerialization.data(withJSONObject: callback, options: [.withoutEscapingSlashes]),
                   let prepared = try? LaunchSpec(operationID: original.operationID, tool: tool, executable: original.executable,
                       arguments: ["-c", "notify=" + String(decoding: json, as: UTF8.self)] + original.arguments,
                       directory: directory, environment: original.environment) { spec = prepared }
            }
            return (try? AgentIntegration.prepare(spec, root: root, helper: helper)) ?? spec
        }.value
    }
    public func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        let spec = try await base.resolve(tool, directory: directory, prompt: prompt)
        return await prepare(spec)
    }
    public func prepare(_ spec: LaunchSpec) async -> LaunchSpec {
        let root = root, helper = helper
        return await Task.detached { (try? AgentIntegration.prepare(spec, root: root, helper: helper)) ?? spec }.value
    }
}

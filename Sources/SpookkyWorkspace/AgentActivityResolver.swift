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
    public func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        let spec = try await base.resolve(tool, directory: directory, prompt: prompt)
        return await Task.detached { (try? AgentIntegration.prepare(spec, root: root, helper: helper)) ?? spec }.value
    }
}

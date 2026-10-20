import Foundation
import SpookkyCore
import SpookkyRuntime

public struct ProviderModel: Equatable, Sendable {
    public let id: String
    public let name: String
    public let efforts: [String]
    public let defaultEffort: String?
    public let acceptsImages: Bool
    public init(id: String, name: String, efforts: [String] = [], defaultEffort: String? = nil, acceptsImages: Bool = true) {
        self.id = id; self.name = name; self.efforts = efforts; self.defaultEffort = defaultEffort; self.acceptsImages = acceptsImages
    }
}

public struct ProviderModels: Sendable {
    public let models: [ProviderModel]
    public let efforts: [String]
    public let issue: String?
    public init(models: [ProviderModel] = [], efforts: [String] = [], issue: String? = nil) {
        self.models = models; self.efforts = efforts; self.issue = issue
    }
}

public protocol ProviderModelDiscovering: Sendable {
    func models(for tool: SessionTool, directory: String, refresh: Bool) async -> ProviderModels
}

public actor ProviderModelCatalog: ProviderModelDiscovering {
    public static let shared = ProviderModelCatalog()
    private var cached: [String: (Date, ProviderModels)] = [:]
    private var pending: [String: (UUID, Task<ProviderModels, Never>)] = [:]
    private let resolver: any ExecutableResolver
    public init(resolver: any ExecutableResolver = CLIResolver()) { self.resolver = resolver }

    public func models(for tool: SessionTool, directory: String, refresh: Bool = false) async -> ProviderModels {
        guard tool != .shell else { return ProviderModels() }
        do {
            let spec = try await resolver.resolve(tool, directory: directory, prompt: nil)
            let modified = (try? FileManager.default.attributesOfItem(atPath: spec.executable)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let key = tool.rawValue + "|" + spec.executable + "|" + String(modified) + "|" + directory
            if !refresh, let (date, value) = cached[key], Date().timeIntervalSince(date) < 300 { return value }
            if let (_, task) = pending[key] { return await task.value }
            while pending.count >= 2, let (otherKey, (id, task)) = pending.first {
                let result = await task.value
                if pending[otherKey]?.0 == id { finish(otherKey, result: result) }
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
            if let (_, task) = pending[key] { return await task.value }
            if !refresh, let (date, value) = cached[key], Date().timeIntervalSince(date) < 300 { return value }
            let requestID = UUID()
            let task = Task.detached {
                do {
                    let environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, value in value }
                        .filter { !$0.key.hasPrefix("SPOOKKY_") }
                    if tool == .codex {
                        let rpc = try CodexProjectRPC(executable: spec.executable, environment: environment, directory: directory, timeout: 5)
                        do {
                            let result = try await Self.codexModels(connection: rpc)
                            await rpc.close(); return result
                        } catch { await rpc.close(); throw error }
                    }
                    let help = try ProcessRunner.run(spec.executable, ["--help"], timeout: 3, outputLimit: 65_536, environment: environment)
                    guard help.status == 0 else { throw LaunchError.invalid("Provider help is unavailable.") }
                    return Self.claudeModels(help: help.output)
                } catch {
                    return ProviderModels(issue: "Models could not be loaded. Use Default model or enter a model name.")
                }
            }
            pending[key] = (requestID, task)
            let result = await task.value
            if pending[key]?.0 == requestID { finish(key, result: result) }
            return result
        } catch { return ProviderModels(issue: "The provider could not be found. Your model choice is retained.") }
    }

    private func finish(_ key: String, result: ProviderModels) {
        pending[key] = nil
        if cached.count >= 8, let oldest = cached.min(by: { $0.value.0 < $1.value.0 })?.key { cached[oldest] = nil }
        cached[key] = (Date(), result)
    }

    static func codexModels(connection: any CodexProjectConnection) async throws -> ProviderModels {
        var models: [ProviderModel] = [], cursor: String?, seen = Set<String>(), ids = Set<String>()
        for page in 0..<4 {
            var params: [String: Any] = ["limit": 64, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let data = try await connection.request("model/list", params: JSONSerialization.data(withJSONObject: params))
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = response["data"] as? [[String: Any]], rows.count <= 64 else { throw CodexProjectError.invalidResponse }
            for row in rows where row["hidden"] as? Bool != true {
                guard let id = row["model"] as? String, AgentModelSelection(model: id).isValid else { continue }
                guard ids.insert(id).inserted else { continue }
                let efforts = (row["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
                    .filter { AgentModelSelection(effort: $0).isValid }
                let name = row["displayName"] as? String ?? id
                models.append(ProviderModel(id: id, name: String(name.prefix(120)), efforts: Array(efforts.prefix(16)),
                    defaultEffort: row["defaultReasoningEffort"] as? String,
                    acceptsImages: (row["inputModalities"] as? [String])?.contains("image") ?? true))
            }
            cursor = response["nextCursor"] as? String
            guard let cursor else { return ProviderModels(models: models) }
            guard page < 3, seen.insert(cursor).inserted else { throw CodexProjectError.limit }
        }
        throw CodexProjectError.limit
    }

    static func claudeModels(help: String) -> ProviderModels {
        func section(_ option: String) -> String {
            let lines = help.components(separatedBy: .newlines)
            guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(option + " ") }) else { return "" }
            return lines[start...].prefix { line in line == lines[start] || !line.trimmingCharacters(in: .whitespaces).hasPrefix("-") }.joined(separator: " ")
        }
        let description = section("--model")
        let regex = try? NSRegularExpression(pattern: "['\"]([a-zA-Z0-9._-]+)['\"]")
        let range = NSRange(description.startIndex..., in: description)
        var seen = Set<String>()
        let models = (regex?.matches(in: description, range: range) ?? []).compactMap { match -> ProviderModel? in
            guard let range = Range(match.range(at: 1), in: description) else { return nil }
            let id = String(description[range])
            guard seen.insert(id).inserted else { return nil }
            return ProviderModel(id: id, name: id.capitalized)
        }
        let effortDescription = section("--effort")
        let efforts = ["low", "medium", "high", "xhigh", "max", "ultra"].filter { value in
            effortDescription.range(of: "\\b" + value + "\\b", options: .regularExpression) != nil
        }
        return ProviderModels(models: models, efforts: efforts,
                              issue: description.isEmpty ? "This CLI does not advertise model choices. Use its default or a supported model name." : nil)
    }
}

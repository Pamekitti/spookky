import Foundation
import SpookkyCore

extension LaunchSpec {
    func selectingModel(_ selection: AgentModelSelection) throws -> LaunchSpec {
        guard selection.isValid else { throw LaunchError.invalid("Enter a valid model name and reasoning effort.") }
        guard tool != .shell else { return self }
        var options: [String] = []
        if let model = selection.model { options.append("--model=" + model) }
        if let effort = selection.effort {
            if tool == .codex {
                // JSON string escaping also represents a TOML basic string for effort names.
                let quoted = String(decoding: try JSONEncoder().encode(effort), as: UTF8.self)
                options += ["-c", "model_reasoning_effort=" + quoted]
            } else { options.append("--effort=" + effort) }
        }
        guard !options.isEmpty else { return self }
        var arguments = arguments
        arguments.insert(contentsOf: options, at: arguments.firstIndex(of: "--") ?? arguments.endIndex)
        return try LaunchSpec(operationID: operationID, tool: tool, executable: executable,
                              arguments: arguments, directory: directory, environment: environment)
    }
}

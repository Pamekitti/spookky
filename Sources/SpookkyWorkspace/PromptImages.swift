import Foundation
import SpookkyCore

extension LaunchSpec {
    /// Add images only to a fresh launch. The resulting intent is retained for retries.
    func attachingPromptImages(_ paths: [String]) async throws -> LaunchSpec {
        guard tool != .shell, !paths.isEmpty else { return self }
        return try await Task.detached {
            guard paths.count <= 8 else { throw LaunchError.invalid("Attach up to 8 images per prompt.") }
            for path in paths {
                guard path.hasPrefix("/"), !path.contains("\0"), FileManager.default.isReadableFile(atPath: path),
                      let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size > 0, size <= 20 * 1024 * 1024 else {
                    throw LaunchError.invalid("An attached image is missing or exceeds 20 MB. Remove it and paste it again.")
                }
            }
            var arguments = self.arguments
            let separator = arguments.firstIndex(of: "--") ?? arguments.endIndex
            if tool == .codex {
                arguments.insert(contentsOf: paths.flatMap { ["--image", $0] }, at: separator)
            } else {
                let references = "Attached images:\n" + paths.joined(separator: "\n")
                if separator < arguments.endIndex, separator + 1 < arguments.endIndex {
                    arguments[separator + 1] += "\n\n" + references
                } else { arguments += ["--", references] }
            }
            return try LaunchSpec(operationID: operationID, tool: tool, executable: executable,
                arguments: arguments, directory: directory, environment: environment)
        }.value
    }
}

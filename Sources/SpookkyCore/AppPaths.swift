import Foundation

public struct AppPaths: Sendable {
    public let data: URL
    public let runtime: URL
    public let production: Bool

    public init(bundleID: String?, home: URL, userID: UInt32, environment: [String: String] = ProcessInfo.processInfo.environment) {
        production = bundleID == "dev.spookky.app"
        let support = home.appendingPathComponent("Library/Application Support/Spookky")
        if production {
            data = support
            runtime = URL(fileURLWithPath: "/tmp/spookky-app-\(userID)")
        } else {
            data = environment["SPOOKKY_M1_DATA"].map { URL(fileURLWithPath: $0) } ?? support.appendingPathComponent("Development")
            runtime = URL(fileURLWithPath: environment["SPOOKKY_M1_ROOT"] ?? "/tmp/spookky-m1-\(userID)")
        }
    }
}

public enum PackagedRuntime {
    public static func tmux(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment,
                            directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> String {
        let production = bundle.bundleIdentifier == "dev.spookky.app"
        let packaged = bundle.executableURL?.deletingLastPathComponent().appendingPathComponent("tmux").path
        var candidates = [String]()
        if !production, let override = environment["SPOOKKY_TMUX"] { candidates.append(override) }
        if let packaged { candidates.append(packaged) }
        if !production { candidates.append(directory.appendingPathComponent(".cache/runtime/bin/tmux").path) }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw LaunchError.invalid("Spookky's terminal runtime is missing. Build the pinned runtime or reinstall Spookky.")
        }
        return executable
    }
}

import Foundation
import CryptoKit

public struct AppPaths: Sendable {
    public let data: URL
    public let runtime: URL
    public let production: Bool
    public let developmentID: String?

    public init(bundleID: String?, home: URL, userID: UInt32, environment: [String: String] = ProcessInfo.processInfo.environment,
                developmentCheckout: String? = Bundle.main.object(forInfoDictionaryKey: "SpookkyDevelopmentCheckout") as? String) {
        production = bundleID == "dev.spookky.app"
        if !production, let checkout = developmentCheckout, !checkout.isEmpty {
            let canonical = URL(fileURLWithPath: checkout).standardizedFileURL.resolvingSymlinksInPath().path
            developmentID = String(SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
        } else { developmentID = nil }
        let support = home.appendingPathComponent("Library/Application Support/Spookky")
        if production {
            data = support
            runtime = URL(fileURLWithPath: "/tmp/spookky-app-\(userID)")
        } else {
            let development = support.appendingPathComponent("Development")
            data = environment["SPOOKKY_M1_DATA"].map { URL(fileURLWithPath: $0) } ?? developmentID.map { development.appendingPathComponent($0) } ?? development
            runtime = URL(fileURLWithPath: environment["SPOOKKY_M1_ROOT"] ?? developmentID.map { "/tmp/spookky-dev-\(userID)-\($0)" } ?? "/tmp/spookky-m1-\(userID)")
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

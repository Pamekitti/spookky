import Foundation

@MainActor enum ApplicationArguments {
    static func isHarnessFlag(_ value: String) -> Bool {
        value.hasPrefix("--workspace-benchmark") || value.hasPrefix("--benchmark-") ||
        ["--terminal-harness", "--workspace", "--workspace-measure", "--self-test", "--input-fixture", "--input-replay", "--folder-probe", "--output-load", "--interactive-checks", "--claude-smoke", "--direct", "--retain", "--lines-per-second"].contains(value)
    }
#if SPOOKKY_HARNESS
    static var override: [String]?
    static var values: [String] { override ?? CommandLine.arguments }
#else
    static var values: [String] { CommandLine.arguments }
#endif
}

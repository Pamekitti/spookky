import Foundation
import XCTest
import SpookkyCore
import SpookkyRuntime

public enum TestGit {
    public static var environment: [String: String] {
        var values = ProcessInfo.processInfo.environment
        for key in ["GIT_CONFIG", "GIT_CONFIG_PARAMETERS"] { values[key] = nil }
        values["GIT_CONFIG_NOSYSTEM"] = "1"
        values["GIT_CONFIG_SYSTEM"] = "/dev/null"
        values["GIT_CONFIG_GLOBAL"] = "/dev/null"
        values["GIT_CONFIG_COUNT"] = "0"
        values["GIT_TERMINAL_PROMPT"] = "0"
        return values
    }
    public static func run(_ path: String, _ arguments: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try ProcessRunner.run("/usr/bin/git", ["-C", path] + arguments, environment: environment)
        XCTAssertEqual(result.status, 0, result.error, file: file, line: line)
    }
}

public enum TestRuntime {
    public static func make(bundle: Bundle, prefix: String = "spookky-test-") throws -> (TmuxRuntime, URL) {
        let root = try TestDirectories.make(prefix: prefix)
        return (try TmuxRuntime(executable: PackagedRuntime.tmux(), helper: TestExecutables.launchHelper(bundle: bundle), root: root), root)
    }
}

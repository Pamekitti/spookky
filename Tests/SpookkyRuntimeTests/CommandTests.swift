import XCTest
import SpookkyCore
import SpookkyRuntime

final class CommandTests: XCTestCase {
    func testLiteralShellArgumentsAndTimeout() throws {
        let values = ["café's 日本語", "$(touch SHOULD_NOT_EXIST)", "line\nbreak", ""]
        let result = try ProcessRunner.run("/bin/zsh", ["-f", "-c", ShellCommand.render(["/usr/bin/printf", "%s\n"] + values)])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, values.joined(separator: "\n") + "\n")
        let start = Date()
        XCTAssertThrowsError(try ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.02))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}

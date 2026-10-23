import Foundation
import XCTest

public func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(value, file: file, line: line)
}
public func requireValue<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
public func expectThrows<E: Error, T>(_ type: E.Type, file: StaticString = #filePath, line: UInt = #line, _ operation: () throws -> T) {
    do { _ = try operation(); XCTFail("Expected \(type)", file: file, line: line) }
    catch is E { }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
public func expectThrowsAsync<E: Error, T>(_ type: E.Type, file: StaticString = #filePath, line: UInt = #line, _ operation: () async throws -> T) async {
    do { _ = try await operation(); XCTFail("Expected \(type)", file: file, line: line) }
    catch is E { }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
public enum TestExecutables {
    public static func launchHelper(bundle: Bundle) -> String {
        if let override = ProcessInfo.processInfo.environment["SPOOKKY_TEST_HELPER"] { return override }
        return bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("spookky-launch").path
    }
}

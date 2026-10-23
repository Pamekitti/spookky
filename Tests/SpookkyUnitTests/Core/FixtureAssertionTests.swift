import Foundation
import XCTest
import SpookkyTestSupport

final class FixtureAssertionTests: XCTestCase {
    func testIncompleteMalformedAndNonBooleanReportsFail() {
        for text in ["", "{", "{}", "{\"binary_unchanged\":true}", "{\"input\":1}", "{\"input\":null}", "{\"input\":false}"] {
            XCTAssertThrowsError(try FixtureAssertions.decode(Data(text.utf8), required: ["input"]))
        }
    }
    func testValidBehaviorRequiresDeclaredAssertions() throws {
        let data = Data("{\"input\":true}".utf8)
        XCTAssertEqual(try FixtureAssertions.decode(data, required: ["input"]), ["input":true])
        XCTAssertThrowsError(try FixtureAssertions.decode(data, required: []))
        XCTAssertThrowsError(try FixtureAssertions.decode(data, required: ["input", "retention"]))
    }
}

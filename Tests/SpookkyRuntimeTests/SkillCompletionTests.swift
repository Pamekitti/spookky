import Foundation
import XCTest
import SpookkyCore

final class SkillCompletionTests: XCTestCase {
    func testTokenAtCaretPreservesSurroundingPrompt() {
        let text = "Please use $sim for this\nnext line"
        let caret = ("Please use $sim" as NSString).length
        let token = SkillCompletionToken.atCaret(in: text, selection: NSRange(location: caret, length: 0))
        XCTAssertEqual(token?.query, "sim")
        XCTAssertEqual(token?.range, NSRange(location: 11, length: 4))
        XCTAssertEqual((text as NSString).replacingCharacters(in: token!.range, with: "$simplify"),
                       "Please use $simplify for this\nnext line")
    }

    func testSlashTokenAndNonTokens() {
        XCTAssertEqual(SkillCompletionToken.atCaret(in: "/sim", selection: NSRange(location: 4, length: 0))?.query, "sim")
        XCTAssertNil(SkillCompletionToken.atCaret(in: "path/to", selection: NSRange(location: 7, length: 0)))
        XCTAssertNil(SkillCompletionToken.atCaret(in: "$simx", selection: NSRange(location: 4, length: 0)))
        XCTAssertNil(SkillCompletionToken.atCaret(in: "$sim", selection: NSRange(location: 4, length: 1)))
    }
}

import XCTest
import CryptoKit
@testable import SpookkyRuntime

final class ViewportGridTests: XCTestCase {
    func testAnchorDigestPreservesPersistedEncoding() throws {
        for text in ["", "ASCII", "日本語café's", "cafe\u{301}"] {
            let grid = try XCTUnwrap(ViewportGrid(physical: text + "\n", joined: text + "\n"))
            let anchor = try XCTUnwrap(grid.anchor(at: 0))
            let expected = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(anchor.digest, expected)
            XCTAssertTrue(anchor.isValid)
        }
    }

    func testWrappedAnchorSurvivesDifferentWidthsAndAppendedOutput() throws {
        let old = try XCTUnwrap(ViewportGrid(physical: "header\n日本語 café\n's text\nnext\n", joined: "header\n日本語 café's text\nnext\n"))
        let anchor = try XCTUnwrap(old.anchor(at: 1))
        let new = try XCTUnwrap(ViewportGrid(physical: "hea\nder\n日本語\n café's\n text\nnext\nmore\n", joined: "header\n日本語 café's text\nnext\nmore\n"))
        XCTAssertEqual(new.row(for: anchor), 2)
        let continuation = try XCTUnwrap(old.anchor(at: 2))
        XCTAssertEqual(new.row(for: continuation), 3)
        XCTAssertNil(ViewportGrid(physical: "changed\n", joined: "different\n"))
    }
}

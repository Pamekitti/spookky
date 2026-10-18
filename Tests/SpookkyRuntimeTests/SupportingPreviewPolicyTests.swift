import XCTest
import SpookkyFiles

final class SupportingPreviewPolicyTests: XCTestCase {
    func testAddressesRemainDataAndRejectScriptAndCredentials() {
        for input in ["javascript:alert(1)", "data:text/html,<script>alert(1)</script>", "about:config", "https://user:password@example.com", "https://example.com\u{0}"] {
            XCTAssertEqual(BrowserAddress.parse(input), .invalid, input)
        }
        XCTAssertEqual(BrowserAddress.parse("about:blank"), .page(URL(string: "about:blank")!))
        XCTAssertEqual(BrowserAddress.parse("localhost:48779/a b/ไทย"), .page(URL(string: "http://localhost:48779/a b/ไทย")!))
        XCTAssertEqual(BrowserAddress.parse("127.0.0.1:48779"), .page(URL(string: "http://127.0.0.1:48779")!))
        XCTAssertEqual(BrowserAddress.parse("example.com"), .page(URL(string: "https://example.com")!))
        XCTAssertEqual(BrowserAddress.parse("mailto:test@example.com"), .external(URL(string: "mailto:test@example.com")!))
        XCTAssertEqual(BrowserAddress.parse("file:///tmp/test.html"), .external(URL(string: "file:///tmp/test.html")!))
        XCTAssertEqual(BrowserAddress.parse("https://example.com/" + String(repeating: "x", count: 16_384)), .invalid)
        XCTAssertEqual(BrowserAddress.parse("https://example.com/" + String(repeating: "泰", count: 2000)), .invalid)
    }
    func testBoundedArtifactsAndHostilePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("spaces ไทย $(touch nope) `data`.md")
        let text = "# Heading\n<script>alert('data')</script>\n$(touch nope)"
        try Data(text.utf8).write(to: file)
        let payload = try ArtifactPreviewPolicy.read(path: file.path)
        XCTAssertEqual(payload.kind, .markdown); XCTAssertEqual(String(decoding: payload.data, as: UTF8.self), text)
        XCTAssertThrowsError(try ArtifactPreviewPolicy.read(path: root.appendingPathComponent("missing.md").path))
        XCTAssertThrowsError(try ArtifactPreviewPolicy.read(path: root.path))
        let unknown = root.appendingPathComponent("unknown.bin"); try Data([1]).write(to: unknown)
        XCTAssertThrowsError(try ArtifactPreviewPolicy.read(path: unknown.path))
        let big = root.appendingPathComponent("big.txt"); try Data(repeating: 32, count: FileService.previewBytes + 1).write(to: big)
        XCTAssertThrowsError(try ArtifactPreviewPolicy.read(path: big.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("nope").path))
    }
    func testHTMLPolicyPrecedesHostileDocumentAndAllowsOnlyInlineScripts() throws {
        let html = "<base href='file:///tmp/'><meta http-equiv='Content-Security-Policy' content='default-src *'><script>counter++</script>"
        let document = try ArtifactPreviewPolicy.sandboxedHTML(Data(html.utf8))
        XCTAssertTrue(document.hasPrefix("<!doctype html><meta http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(document.contains("connect-src 'none'"))
        XCTAssertTrue(document.contains("base-uri 'none'"))
        XCTAssertTrue(document.contains("script-src 'unsafe-inline'"))
        XCTAssertTrue(document.hasSuffix(html))
        XCTAssertThrowsError(try ArtifactPreviewPolicy.sandboxedHTML(Data([0xff])))
    }
}

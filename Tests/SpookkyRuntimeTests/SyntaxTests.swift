import XCTest
import SpookkySyntax
import SpookkyGit

final class SyntaxTests: XCTestCase {
    func testEverydayLanguagesAndSourcePreservation() async throws {
        let examples: [(String, String)] = [
            ("sample.swift", "let value = \"hello\""), ("sample.py", "value = \"hello\""),
            ("sample.js", "const value = \"hello\";"), ("sample.jsx", "const value = <div title=\"hello\" />;"),
            ("sample.ts", "const value: string = \"hello\";"), ("sample.tsx", "const value = <div title=\"hello\" />;"),
            ("sample.rs", "let value = \"hello\";"), ("sample.go", "package main\nvar value = \"hello\""),
            ("sample.sh", "echo \"hello\""), ("sample.json", "{\"value\": true}"),
            ("sample.yaml", "value: true"), ("sample.toml", "value = \"hello\""),
            ("sample.html", "<div title=\"hello\">hello</div>"), ("sample.css", "div { color: red; }"),
            ("sample.sql", "SELECT name FROM people WHERE id = 3;"), ("sample.md", "# Heading\n**hello**")]
        let highlighter = SyntaxHighlighter()
        for (path, text) in examples {
            let document = try await highlighter.highlight(text, path: path)
            XCTAssertNotNil(document, path)
            XCTAssertEqual(document?.lines.map(\.text).joined(separator: "\n"), text, path)
            XCTAssertTrue(document?.lines.contains { !$0.spans.isEmpty } == true, path)
        }
    }
    func testUnicodeTabsAndMultilineState() async throws {
        let source = "let café = \"👩🏽‍💻 & <hello>\"\n/* first\n\tsecond β line */\nlet n = 42\n"
        let result = try await SyntaxHighlighter().highlight(source, path: "unicode.swift")
        let document = try XCTUnwrap(result)
        XCTAssertEqual(document.lines.map(\.text).joined(separator: "\n"), source)
        let functions = try await SyntaxHighlighter().highlight("func greet() { print(1) }", path: "functions.swift")
        XCTAssertTrue(functions?.lines[0].spans.contains { $0.role == .function } == true)
        XCTAssertTrue(document.lines[2].spans.contains { $0.role == .comment })
        XCTAssertTrue(document.lines[3].spans.contains { $0.role == .number })
        for line in document.lines {
            for span in line.spans { XCTAssertLessThanOrEqual(NSMaxRange(span.range), line.text.utf16.count) }
        }
    }
    func testCommentStateOutsideVisibleDiffHunk() async throws {
        let source = "/*\n" + String(repeating: "inside\n", count: 30) + "*/\n"
        var lines = source.components(separatedBy: "\n")
        lines[12] = "updated inside"
        let highlighter = SyntaxHighlighter()
        let old = try await highlighter.highlight(source, path: "comment.swift")
        let new = try await highlighter.highlight(lines.joined(separator: "\n"), path: "comment.swift")
        let patch = GitChanges.parsePatch("@@ -12,3 +12,3 @@\n inside\n-inside\n+updated inside\n inside\n")
        let removed = try XCTUnwrap(patch.lines.first { $0.kind == .removal })
        let added = try XCTUnwrap(patch.lines.first { $0.kind == .addition })
        let oldLine = try XCTUnwrap(old?.lines[(removed.old ?? 0) - 1])
        let newLine = try XCTUnwrap(new?.lines[(added.new ?? 0) - 1])
        XCTAssertEqual(oldLine.text, removed.text); XCTAssertEqual(newLine.text, added.text)
        XCTAssertTrue(oldLine.spans.contains { $0.role == .comment })
        XCTAssertTrue(newLine.spans.contains { $0.role == .comment })
    }
    func testLargeBoundedDocumentRanges() async throws {
        let source = (0..<5_000).map { String(format: "%05d ", $0) + String(repeating: "x", count: 201) + "\n" }.joined()
        let started = ProcessInfo.processInfo.systemUptime
        let document = try await SyntaxHighlighter().highlight(source, path: "large.swift")
        XCTAssertEqual(document?.lines.map(\.text).joined(separator: "\n"), source)
        XCTAssertLessThan(document?.cost ?? Int.max, 32 * 1024 * 1024)
        XCTAssertTrue(document?.lines[0].spans.contains { $0.role == .number } == true)
        print("SPOOKKY_SYNTAX_FIXTURE_MS=\((ProcessInfo.processInfo.systemUptime - started) * 1000)")
    }
    func testUnknownMalformedAndSizeLimits() async throws {
        let highlighter = SyntaxHighlighter()
        let unknown = try await highlighter.highlight("ordinary text", path: "sample.txt")
        XCTAssertNil(unknown)
        let malformed = try await highlighter.highlight("func broken( { let x = \"unfinished", path: "broken.swift")
        XCTAssertNotNil(malformed)
        XCTAssertEqual(SyntaxHighlighter.language(path: "script", text: "#!/usr/bin/env python3\nprint(1)"), "python")
        for source in [String(repeating: "x", count: 2 * 1024 * 1024 + 1), String(repeating: "\n", count: 20_000)] {
            do { _ = try await highlighter.highlight(source, path: "large.swift"); XCTFail("Expected bounded highlighting") }
            catch SyntaxFailure.limit { }
        }
    }
}

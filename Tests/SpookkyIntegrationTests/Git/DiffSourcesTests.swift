import XCTest
import SpookkyGit

final class DiffSourcesTests: XCTestCase {
    func testVersionedSourcesRenameAndConcurrentEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-source-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitRepository(), changes = GitChanges()
        _ = try await git.executor.execute(["init", "--initial-branch=dev", root.path]).checked()
        func command(_ args: [String]) async throws { _ = try await git.command(root.path, args).checked() }
        try await command(["config", "user.name", "Fixture"])
        try await command(["config", "user.email", "fixture@example.invalid"])
        let name = "old ' β.swift", renamed = "new ' β.swift"
        let original = "/* first\nsecond */\nlet value = 1\n"
        let staged = original.replacingOccurrences(of: "1", with: "2")
        let working = original.replacingOccurrences(of: "1", with: "3")
        try original.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try await command(["add", "--", name]); try await command(["commit", "-m", "Fixture"])
        try staged.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try await command(["add", "--", name])
        try working.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        var snapshot = try await changes.snapshot(root: root.path)
        for group in [ChangeGroup.staged, .unstaged] {
            let file = try XCTUnwrap(snapshot.files.first { $0.group == group })
            let diff = try await changes.diff(root: root.path, file: file, snapshot: snapshot)
            let sources = try await changes.sources(root: root.path, file: file, snapshot: snapshot, expectedWorktreeSignature: diff.worktreeSignature)
            XCTAssertEqual(sources.old, group == .staged ? original : staged)
            XCTAssertEqual(sources.new, group == .staged ? staged : working)
        }
        try await command(["mv", "--", name, renamed])
        try working.write(to: root.appendingPathComponent(renamed), atomically: true, encoding: .utf8)
        snapshot = try await changes.snapshot(root: root.path)
        let file = try XCTUnwrap(snapshot.files.first { $0.group == .unstaged })
        let diff = try await changes.diff(root: root.path, file: file, snapshot: snapshot)
        let sources = try await changes.sources(root: root.path, file: file, snapshot: snapshot, expectedWorktreeSignature: diff.worktreeSignature)
        XCTAssertEqual(sources.old, staged); XCTAssertEqual(sources.new, working)
        try (working + "// changed\n").write(to: root.appendingPathComponent(renamed), atomically: true, encoding: .utf8)
        do {
            _ = try await changes.sources(root: root.path, file: file, snapshot: snapshot, expectedWorktreeSignature: diff.worktreeSignature)
            XCTFail("Changed sources must not color the previous diff")
        } catch ChangesError.changed { }
    }
    func testUnbornAddCommittedComparisonAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-source-kinds-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitRepository(), changes = GitChanges()
        _ = try await git.executor.execute(["init", "--initial-branch=dev", root.path]).checked()
        func command(_ args: [String]) async throws { _ = try await git.command(root.path, args).checked() }
        try await command(["config", "user.name", "Fixture"])
        try await command(["config", "user.email", "fixture@example.invalid"])
        let fileURL = root.appendingPathComponent("sample.swift"), source = "let value = 1\n"
        try source.write(to: fileURL, atomically: true, encoding: .utf8)
        try await command(["add", "sample.swift"])
        var snapshot = try await changes.snapshot(root: root.path)
        var file = try XCTUnwrap(snapshot.files.first)
        var pair = try await changes.sources(root: root.path, file: file, snapshot: snapshot, expectedWorktreeSignature: nil)
        XCTAssertNil(pair.old); XCTAssertEqual(pair.new, source)
        try await command(["commit", "-m", "Fixture"]); try await command(["branch", "base"])
        let modified = "let value = 2\n"
        try modified.write(to: fileURL, atomically: true, encoding: .utf8)
        try await command(["add", "sample.swift"]); try await command(["commit", "-m", "Changed"])
        snapshot = try await changes.snapshot(root: root.path, reference: "base")
        file = try XCTUnwrap(snapshot.files.first)
        pair = try await changes.sources(root: root.path, file: file, snapshot: snapshot, expectedWorktreeSignature: nil)
        XCTAssertEqual(pair.old, source); XCTAssertEqual(pair.new, modified)
        try await command(["rm", "sample.swift"])
        snapshot = try await changes.snapshot(root: root.path)
        file = try XCTUnwrap(snapshot.files.first)
        pair = try await changes.sources(root: root.path, file: file, snapshot: snapshot, expectedWorktreeSignature: nil)
        XCTAssertEqual(pair.old, modified); XCTAssertNil(pair.new)
    }

}

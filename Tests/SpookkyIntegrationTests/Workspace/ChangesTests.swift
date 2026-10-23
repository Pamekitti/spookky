import XCTest
import SpookkyGit

final class ChangesTests: XCTestCase {
    func testLiteralPathsAndComparisons() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-m3-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitRepository(), changes = GitChanges()
        _ = try await git.executor.execute(["init", "--initial-branch=dev", root.path]).checked()
        _ = try await git.command(root.path, ["config", "user.name", "Fixture"]).checked()
        _ = try await git.command(root.path, ["config", "user.email", "fixture@example.invalid"]).checked()
        let name = "a ' 世界\n.txt", url = root.appendingPathComponent(name)
        try Data("one\n".utf8).write(to: url)
        _ = try await git.command(root.path, ["add", "--", name]).checked()
        let unborn = try await changes.snapshot(root: root.path)
        XCTAssertNil(unborn.head); XCTAssertEqual(unborn.files.first?.group, .staged)
        let initial = try await changes.diff(root: root.path, file: unborn.files[0], snapshot: unborn)
        XCTAssertTrue(initial.lines.contains { $0.kind == .addition && $0.text == "one" })
        _ = try await git.command(root.path, ["commit", "-m", "initial"]).checked()
        _ = try await git.command(root.path, ["branch", "base"]).checked()
        try Data("two\n".utf8).write(to: url)
        _ = try await git.command(root.path, ["add", "--", name]).checked()
        try Data("three\n".utf8).write(to: url)
        let snapshot = try await changes.snapshot(root: root.path)
        XCTAssertEqual(snapshot.files.map(\.group), [.staged, .unstaged])
        let staged = try await changes.diff(root: root.path, file: snapshot.files[0], snapshot: snapshot)
        let unstaged = try await changes.diff(root: root.path, file: snapshot.files[1], snapshot: snapshot)
        XCTAssertTrue(staged.lines.contains { $0.kind == .addition && $0.text == "two" })
        XCTAssertTrue(unstaged.lines.contains { $0.kind == .addition && $0.text == "three" })
        _ = try await git.command(root.path, ["commit", "-m", "staged change"]).checked()
        let comparison = try await changes.snapshot(root: root.path, reference: "base")
        XCTAssertEqual(comparison.files.count, 1)
        let committed = try await changes.diff(root: root.path, file: comparison.files[0], snapshot: comparison)
        XCTAssertTrue(committed.lines.contains { $0.kind == .addition && $0.text == "two" })
        XCTAssertFalse(committed.lines.contains { $0.text == "three" })
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "three\n")
        let current = try await changes.snapshot(root: root.path)
        _ = try await git.command(root.path, ["add", "--", name]).checked()
        do { _ = try await changes.diff(root: root.path, file: current.files[0], snapshot: current); XCTFail("Accepted replaced index with unchanged HEAD") } catch {}
        _ = try await git.command(root.path, ["branch", "-f", "base", "HEAD"]).checked()
        do { _ = try await changes.diff(root: root.path, file: comparison.files[0], snapshot: comparison); XCTFail("Accepted moved comparison ref") } catch {}
        do { _ = try await changes.diff(root: root.path, file: snapshot.files[0], snapshot: snapshot); XCTFail("Accepted stale index") } catch {}
    }
    func testStatusNamesAndPatchBounds() throws {
        let files = try GitChanges.parseStatus(Data("R  new name\0old name\0UU conflict\0?? untracked\0".utf8))
        XCTAssertEqual(files[0].oldPath, "old name"); XCTAssertEqual(files[1].group, .conflicts)
        let unsupported = try GitChanges.parseStatus(Data([63, 63, 32, 255, 0]))
        XCTAssertFalse(unsupported[0].supported)
        let patch = GitChanges.parsePatch("@@ -2,1 +2,2 @@\n-old\n+new\n+extra\n")
        XCTAssertEqual(patch.lines[1].old, 2); XCTAssertEqual(patch.lines[3].new, 3)
        XCTAssertNotNil(GitChanges.parsePatch(String(repeating: "+line\n", count: 25_000)).notice)
    }
}

extension ChangesTests {
    func testSpecialStatesAndConflictStages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-m3-special-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitRepository(), changes = GitChanges()
        _ = try await git.executor.execute(["init", "--initial-branch=dev", root.path]).checked()
        _ = try await git.command(root.path, ["config", "user.name", "Fixture"]).checked()
        _ = try await git.command(root.path, ["config", "user.email", "fixture@example.invalid"]).checked()
        for name in ["rename", "delete", "mode", "conflict"] { try Data((name + "\n").utf8).write(to: root.appendingPathComponent(name)) }
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "mode")
        _ = try await git.command(root.path, ["add", "."]).checked()
        _ = try await git.command(root.path, ["commit", "-m", "initial"]).checked()
        _ = try await git.command(root.path, ["branch", "other"]).checked()
        try Data("ours\n".utf8).write(to: root.appendingPathComponent("conflict"))
        _ = try await git.command(root.path, ["commit", "-am", "ours"]).checked()
        _ = try await git.command(root.path, ["checkout", "other"]).checked()
        try Data("theirs\n".utf8).write(to: root.appendingPathComponent("conflict"))
        _ = try await git.command(root.path, ["commit", "-am", "theirs"]).checked()
        _ = try await git.command(root.path, ["checkout", "dev"]).checked()
        _ = try await git.command(root.path, ["merge", "other"])
        _ = try await git.command(root.path, ["mv", "rename", "renamed"]).checked()
        try FileManager.default.removeItem(at: root.appendingPathComponent("delete"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("mode").path)
        try Data([0, 4, 5]).write(to: root.appendingPathComponent("binary"))
        let before = try await changes.fingerprint(root.path)
        let snapshot = try await changes.snapshot(root: root.path)
        XCTAssertEqual(snapshot.files.first { $0.path == "renamed" }?.oldPath, "rename")
        XCTAssertEqual(snapshot.files.first { $0.path == "delete" }?.status, "D")
        let conflict = try XCTUnwrap(snapshot.files.first { $0.group == .conflicts })
        for (stage, value) in [(1, "conflict\n"), (2, "ours\n"), (3, "theirs\n")] {
            let data = try await changes.conflictStage(root: root.path, file: conflict, stage: stage)
            XCTAssertEqual(String(data: data, encoding: .utf8), value)
        }
        for file in snapshot.files where file.group != .conflicts {
            let diff = try await changes.diff(root: root.path, file: file, snapshot: snapshot)
            if file.path == "binary" { XCTAssertTrue(diff.lines.contains { $0.text.contains("Binary files") }) }
            if file.path == "mode" { XCTAssertTrue(diff.lines.contains { $0.text.contains("mode") }) }
        }
        let after = try await changes.fingerprint(root.path); XCTAssertEqual(before, after)
    }
    func testBoundedOutputAndCancellation() async throws {
        let limited = GitChanges(git: GitRepository(executor: TruncatedChangesExecutor()))
        do { _ = try await limited.snapshot(root: "/tmp"); XCTFail("Accepted partial status") } catch {}
        let task = Task { try await GitChanges().snapshot(root: "/tmp") }; task.cancel()
        do { _ = try await task.value; XCTFail("Ignored cancellation") } catch {}
    }
}
private struct TruncatedChangesExecutor: GitCommandExecutor {
    func execute(_ arguments: [String]) async throws -> GitResult { GitResult(status: 0, output: "?? partial", truncated: true) }
}

extension ChangesTests {
    func testDeletedRenamedSubmoduleAndMissingBaseParsing() throws {
        let files = try GitChanges.parseNames(Data("R100\0old\0new\0D\0deleted\0M\0module\0".utf8))
        XCTAssertEqual(files.map(\.path), ["new", "deleted", "module"])
        XCTAssertEqual(files[0].oldPath, "old")
        let patch = GitChanges.parsePatch("diff --git a/module b/module\n@@ -1 +1 @@\n-Subproject commit abc\n+Subproject commit def-dirty\n")
        XCTAssertTrue(patch.lines.contains { $0.text == "Subproject commit def-dirty" })
        XCTAssertFalse(patch.lines.contains { $0.text.hasPrefix("diff --git") })
    }
}

extension ChangesTests {
    func testReadDoesNotExecuteConfiguredContentFilters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-m3-filter-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitRepository(), changes = GitChanges()
        _ = try await git.executor.execute(["init", root.path]).checked()
        try Data("*.txt filter=fixture\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        try Data("hello\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = try await git.command(root.path, ["add", "."]).checked()
        _ = try await git.command(root.path, ["config", "filter.fixture.clean", "touch '" + root.appendingPathComponent("executed").path + "'; cat"]).checked()
        _ = try await git.command(root.path, ["config", "filter.fixture.required", "true"]).checked()
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        let snapshot = try await changes.snapshot(root: root.path)
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "file.txt" && $0.group == .unstaged })
        let diff = try await changes.diff(root: root.path, file: file, snapshot: snapshot)
        XCTAssertTrue(diff.notice?.contains("filters are disabled") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("executed").path))
    }
}

extension ChangesTests {
    func testSubmoduleCommitScopeDoesNotRunNestedFilters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spookky-m3-module-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), parent = root.appendingPathComponent("parent")
        let git = GitRepository(), changes = GitChanges()
        for repo in [source, parent] {
            _ = try await git.executor.execute(["init", repo.path]).checked()
            _ = try await git.command(repo.path, ["config", "user.name", "Fixture"]).checked()
            _ = try await git.command(repo.path, ["config", "user.email", "fixture@example.invalid"]).checked()
        }
        try Data("first\n".utf8).write(to: source.appendingPathComponent("file.txt"))
        _ = try await git.command(source.path, ["add", "."]).checked()
        _ = try await git.command(source.path, ["commit", "-m", "initial"]).checked()
        _ = try await git.command(parent.path, ["-c", "protocol.file.allow=always", "submodule", "add", source.path, "module"]).checked()
        _ = try await git.command(parent.path, ["commit", "-am", "module"]).checked()
        let module = parent.appendingPathComponent("module")
        for (key, value) in [("user.name", "Fixture"), ("user.email", "fixture@example.invalid"), ("filter.fixture.clean", "touch '" + root.appendingPathComponent("executed").path + "'; cat")] {
            _ = try await git.command(module.path, ["config", key, value]).checked()
        }
        try Data("*.txt filter=fixture\n".utf8).write(to: module.appendingPathComponent(".gitattributes"))
        try Data("second\n".utf8).write(to: module.appendingPathComponent("file.txt"))
        let nested = try await changes.snapshot(root: parent.path)
        XCTAssertTrue(nested.notice?.contains("Open submodules as workspaces") == true)
        XCTAssertTrue(nested.files.isEmpty)
        _ = try await git.command(module.path, ["-c", "filter.fixture.clean=", "add", "file.txt"]).checked()
        _ = try await git.command(module.path, ["-c", "filter.fixture.clean=", "commit", "-m", "advance"]).checked()
        _ = try await git.command(parent.path, ["-c", "filter.fixture.clean=", "checkout", "--detach"]).checked()
        let snapshot = try await changes.snapshot(root: parent.path)
        let file = try XCTUnwrap(snapshot.files.first { $0.path == "module" })
        let diff = try await changes.diff(root: parent.path, file: file, snapshot: snapshot)
        XCTAssertTrue(diff.lines.contains { $0.kind == .addition && $0.text.hasPrefix("Subproject commit") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("executed").path))
    }
}

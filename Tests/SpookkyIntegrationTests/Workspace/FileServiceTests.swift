import XCTest
import SpookkyFiles

final class FileServiceTests: XCTestCase {
    func testScopeAndSpecialFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["folder", ".git", "nested/.git"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
        try Data("hello\n世界".utf8).write(to: root.appendingPathComponent("a ' 🌱\n.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/etc")
        let service = FileService()
        let listing = try await service.list(root: root.path)
        XCTAssertFalse(listing.entries.contains { $0.name == ".git" })
        XCTAssertEqual(listing.entries.first { $0.name == "nested" }?.kind, .repository)
        let preview = try await service.preview(root: root.path, path: "a ' 🌱\n.txt")
        XCTAssertEqual(preview.text, "hello\n世界")
        let link = try await service.preview(root: root.path, path: "outside")
        XCTAssertTrue(link.notice?.contains("/etc") == true)
        do { _ = try await service.preview(root: root.path, path: "outside/passwd"); XCTFail("Escaped scope") } catch {}
        do { _ = try await service.preview(root: root.path, path: "../outside"); XCTFail("Escaped scope") } catch {}
        let task = Task { try Task.checkCancellation(); return try await service.search(root: root.path, query: "") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Ignored cancellation") } catch is CancellationError {}
    }
    func testBoundsAndSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<20 { try Data("x".utf8).write(to: root.appendingPathComponent("file-\(index)")) }
        let service = FileService()
        let listing = try await service.search(root: root.path, query: "file", visitLimit: 10, matchLimit: 4)
        XCTAssertTrue(listing.incomplete); XCTAssertEqual(listing.entries.count, 4)
        XCTAssertTrue(FileService.decode(Data(repeating: 97, count: 3 * 1024 * 1024)).limited)
        XCTAssertTrue(FileService.decode(Data(String(repeating: "line\n", count: 30_000).utf8)).limited)
        XCTAssertTrue(FileService.decode(Data([0, 1])).notice?.contains("Binary") == true)
        XCTAssertTrue(FileService.decode(Data([255, 254])).notice?.contains("encoding") == true)
    }
}

extension FileServiceTests {
    func testUnreadableDeletedAndFIFO() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = root.appendingPathComponent("denied")
        try Data("fixture".utf8).write(to: secret)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: secret.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path) }
        let service = FileService()
        do { _ = try await service.preview(root: root.path, path: "denied"); XCTFail("Ignored filesystem denial") } catch {}
        do { _ = try await service.preview(root: root.path, path: "missing"); XCTFail("Invented missing content") } catch {}
        XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)
        let value = try await service.preview(root: root.path, path: "pipe")
        XCTAssertTrue(value.notice?.contains("not a regular file") == true)
    }
}

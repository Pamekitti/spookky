import XCTest
import SpookkyCore
import SpookkyGit
import SpookkyPersistence
import ImageIO
import CoreGraphics

private actor AvatarFixture: AvatarDownloading {
    let data: Data
    var fails = false
    var calls = 0
    var active = 0
    var maximumActive = 0
    init(data: Data) { self.data = data }
    func setFailure() { fails = true }
    func download(owner: String) async throws -> Data {
        calls += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(20))
        if fails { throw URLError(.notConnectedToInternet) }
        return data
    }
}

final class SidebarTests: XCTestCase {
    func testCollapsePreservesDraftAndSelectionAndSelectionExpands() throws {
        var state = WorkspaceState()
        let location = WorkspaceLocation(path: "/tmp/sidebar")
        let project = state.registerProject(location)
        let workspace = state.newWorkspace(location: location, projectID: project)
        state.editDraft(state.selectedTab!.id, tool: .codex, prompt: "Keep this unsent draft")
        let before = state.selected
        state.toggleProjectCollapsed(project)
        XCTAssertEqual(state.selected, before)
        XCTAssertEqual(state.projects.first?.isCollapsed, true)
        state.selectWorkspace(workspace)
        XCTAssertEqual(state.projects.first?.isCollapsed, false)
        state.toggleProjectCollapsed(project)
        state.newWorkspace(location: location, projectID: project)
        XCTAssertEqual(state.projects.first?.isCollapsed, false)
        XCTAssertEqual(state.workspaces.first, before)
        try state.validate()
    }
    func testCollapseRoundTripAndOldSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = WorkspaceState()
        let id = state.registerProject(WorkspaceLocation(path: "/tmp/sidebar"))
        state.newWorkspace(directory: "/tmp")
        state.setProjectCollapsed(id, true)
        let database = try WorkspaceDatabase(path: root.appendingPathComponent("state.sqlite").path)
        try await database.save(state)
        let restored = try await database.load()
        XCTAssertEqual(restored?.projects.first?.isCollapsed, true)
        XCTAssertEqual(restored?.version, 7)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        var projects = json["projects"] as! [[String: Any]]
        projects[0].removeValue(forKey: "isCollapsed"); json["projects"] = projects
        let old = try JSONDecoder().decode(WorkspaceState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.projects.first?.isCollapsed)
        try old.validate()
    }
    func testGitHubRemoteFormsAndRejectedHosts() {
        for remote in ["https://github.com/Acme/repo.git", "git@github.com:Acme/repo.git", "ssh://git@github.com:22/Acme/repo.git", "https://github.com/Acme/repo"] {
            XCTAssertEqual(GitHubOwner.parse(remote: remote), "acme")
        }
        for remote in ["https://github.com.evil.test/acme/repo", "https://gitlab.com/acme/repo", "/tmp/repo", "git@github.com:../repo", "https://github.com/acme", "https://github.com/acme/repo/extra", "https://github.com/a%2fb/repo", "https://github.com/acme/repo?token=secret"] {
            XCTAssertNil(GitHubOwner.parse(remote: remote), remote)
        }
    }
    func testAvatarDeduplicationConcurrencyAndMemoryBound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = AvatarFixture(data: try png())
        let cache = GitHubAvatarCache(directory: root, downloader: downloader)
        await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<8 { group.addTask { await cache.image("same-owner") } }
            for await data in group { XCTAssertNotNil(data) }
        }
        let calls = await downloader.calls; XCTAssertEqual(calls, 1)
        await withTaskGroup(of: Data?.self) { group in
            for index in 0..<34 { group.addTask { await cache.image("owner\(index)") } }
            for await data in group { XCTAssertNotNil(data) }
        }
        let maximum = await downloader.maximumActive; XCTAssertEqual(maximum, 2)
        try FileManager.default.removeItem(at: root.appendingPathComponent("same-owner.png"))
        let evicted = await cache.cached("same-owner"); XCTAssertNil(evicted)
    }
    func testOfflineRetainsStaleAvatarAndSuppressesRetries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloader = AvatarFixture(data: try png())
        let cache = GitHubAvatarCache(directory: root, downloader: downloader)
        let old = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let original = await cache.image("acme", now: old)
        await downloader.setFailure()
        let refreshed = await cache.image("acme")
        XCTAssertEqual(original, refreshed)
        _ = await cache.image("acme")
        let calls = await downloader.calls; XCTAssertEqual(calls, 2)
        let empty = await cache.image("unknown"); XCTAssertNil(empty)
        _ = await cache.image("unknown")
        let failedCalls = await downloader.calls; XCTAssertEqual(failedCalls, 3)
    }
    func testInvalidImagesAndDiskBound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = GitHubAvatarCache(directory: root, downloader: AvatarFixture(data: Data(repeating: 0, count: 513 * 1024)))
        let rejected = await invalid.image("invalid"); XCTAssertNil(rejected)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<11 { try Data(repeating: 0, count: 1024 * 1024).write(to: root.appendingPathComponent("old\(index).png")) }
        let cache = GitHubAvatarCache(directory: root, downloader: AvatarFixture(data: try png()))
        let image = await cache.image("acme"); XCTAssertNotNil(image)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(bytes, GitHubAvatarCache.diskLimit)
    }
    private func png() throws -> Data {
        let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

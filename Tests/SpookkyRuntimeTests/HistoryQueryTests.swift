import XCTest
import SpookkyCore
@testable import SpookkyWorkspace

final class HistoryQueryTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spookky-page-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func id(_ number: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", number) }
    private func row(_ number: Int, directory: String, title: String? = nil, updated: Double? = nil) -> [String: Any] {
        ["id": id(number), "cwd": directory, "name": title ?? "Conversation \(number)", "updatedAt": updated ?? Double(10_000 - number)]
    }
    private func codex(root: URL, rows: [[String: Any]], supportsDirectory: Bool = true) throws -> (String, [String: String], URL) {
        let fixture = root.appendingPathComponent("rows.json"), log = root.appendingPathComponent("requests.jsonl")
        try JSONSerialization.data(withJSONObject: rows).write(to: fixture)
        let executable = root.appendingPathComponent("codex-fixture")
        let source = #"""
#!/usr/bin/python3
import json, os, sys
rows = json.load(open(os.environ['SPOOKKY_PAGE_ROWS']))
for line in sys.stdin:
    request = json.loads(line)
    with open(os.environ['SPOOKKY_PAGE_LOG'], 'a') as log:
        log.write(json.dumps(request) + '\n')
    if 'id' not in request:
        continue
    method, params = request['method'], request.get('params', {})
    if method == 'initialize':
        result = {}
    elif method == 'thread/list':
        if 'cwd' in params and os.environ['SPOOKKY_PAGE_CWD'] == '0':
            print(json.dumps(dict(id=request['id'], error=dict(code=-32602, message='unknown cwd filter'))), flush=True)
            continue
        selected = rows
        if 'cwd' in params:
            directories = params['cwd'] if isinstance(params['cwd'], list) else [params['cwd']]
            selected = [r for r in selected if r['cwd'] in directories]
        if 'searchTerm' in params:
            selected = [r for r in selected if params['searchTerm'].casefold() in r['name'].casefold()]
        offset, limit = int(params.get('cursor', '0')), params.get('limit', 100)
        result = dict(data=selected[offset:offset+limit], nextCursor=str(offset+limit) if offset+limit < len(selected) else None)
    else:
        sys.exit(41)
    print(json.dumps(dict(id=request['id'], result=result)), flush=True)
"""#
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable.path, ["SPOOKKY_PAGE_ROWS": fixture.path, "SPOOKKY_PAGE_LOG": log.path,
            "SPOOKKY_PAGE_CWD": supportsDirectory ? "1" : "0"], log)
    }
    private func requests(_ url: URL) throws -> [[String: Any]] {
        try Data(contentsOf: url).split(separator: 10).map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
    }
    private func claude(root: URL, number: Int, title: String, modified: Double) throws {
        let bucket = root.appendingPathComponent("bucket")
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        let file = bucket.appendingPathComponent(id(number) + ".jsonl")
        let values: [[String: Any]] = [["sessionId": id(number), "cwd": root.path, "type": "custom-title", "customTitle": title]]
        let lines = try values.map { try JSONSerialization.data(withJSONObject: $0) + Data([10]) }.reduce(Data(), +)
        try lines.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: file.path)
    }

    func testQueryScopesDirectoriesAndClampsPageSizes() {
        let item = ConversationMetadata(id: ConversationID(provider: .codex, sessionID: id(1)), title: "Café", directory: "/tmp/project/child", updatedAt: Date())
        XCTAssertTrue(HistoryQuery(directories: ["/tmp/project"], search: "café").matches(item))
        XCTAssertFalse(HistoryQuery(directories: ["/tmp/project"], exactDirectories: true).matches(item))
        XCTAssertFalse(HistoryQuery(directories: ["/tmp/pro"]).matches(item))
        XCTAssertTrue(HistoryQuery().matches(item))
        XCTAssertEqual(HistoryQuery(limit: 0).limit, 1)
        XCTAssertEqual(HistoryQuery(limit: 1000).limit, 100)
    }

    func testCodexFirstPageReadsOnlyRequestedMetadataAndPreservesNativeCursor() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try codex(root: root, rows: (1...600).map { row($0, directory: root.path) })
        let first = try CodexHistoryReader.page(executable: fixture.0, environment: fixture.1, query: HistoryQuery(limit: 5))
        XCTAssertEqual(first.conversations.map(\.id.sessionID), (1...5).map(id))
        XCTAssertNotNil(first.nextCursor); XCTAssertFalse(first.truncated)
        let list = try requests(fixture.2).filter { $0["method"] as? String == "thread/list" }
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual((list.first?["params"] as? [String: Any])?["limit"] as? Int, 5)
        let second = try CodexHistoryReader.page(executable: fixture.0, environment: fixture.1,
            query: HistoryQuery(limit: 10), cursor: first.nextCursor)
        XCTAssertEqual(second.conversations.map(\.id.sessionID), (6...15).map(id))
        XCTAssertTrue(try requests(fixture.2).allSatisfy { ["initialize", "initialized", "thread/list"].contains($0["method"] as? String ?? "") })
    }

    func testOlderFilteredHistoryRemainsReachableAfterBoundedEmptyPage() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let older = (201...205).map { row($0, directory: root.appendingPathComponent("project/child").path, title: "Older match") }
        let fixture = try codex(root: root, rows: (1...200).map { row($0, directory: "/tmp/unrelated") } + older)
        let query = HistoryQuery(directories: [root.appendingPathComponent("project").path], search: "match", limit: 5)
        let first = try CodexHistoryReader.page(executable: fixture.0, environment: fixture.1, query: query)
        XCTAssertTrue(first.conversations.isEmpty); XCTAssertTrue(first.truncated); XCTAssertNotNil(first.nextCursor)
        let second = try CodexHistoryReader.page(executable: fixture.0, environment: fixture.1, query: query, cursor: first.nextCursor)
        XCTAssertEqual(second.conversations.count, 5); XCTAssertNil(second.nextCursor)
    }

    func testNativeTitleSearchReachesAnUncachedOlderConversationWithoutInventoryScan() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try codex(root: root, rows: (1...600).map { row($0, directory: root.path, title: $0 == 600 ? "Older needle" : "Recent \($0)") })
        let page = try CodexHistoryReader.page(executable: fixture.0, environment: fixture.1,
            query: HistoryQuery(search: "needle", limit: 10, titleSearchOnly: true))
        XCTAssertEqual(page.conversations.map(\.id.sessionID), [id(600)])
        let lists = try requests(fixture.2).filter { $0["method"] as? String == "thread/list" }
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual((lists.first?["params"] as? [String: Any])?["searchTerm"] as? String, "needle")
    }

    func testExactDirectoryFilterFallsBackWithoutChangingTheScope() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let rows = [row(1, directory: "/tmp/other"), row(2, directory: root.path), row(3, directory: root.path)]
        let fixture = try codex(root: root, rows: rows, supportsDirectory: false)
        let page = try CodexHistoryReader.page(executable: fixture.0, environment: fixture.1,
            query: HistoryQuery(directories: [root.path], limit: 2, exactDirectories: true))
        XCTAssertEqual(page.conversations.map(\.id.sessionID), [id(2), id(3)])
        let lists = try requests(fixture.2).filter { $0["method"] as? String == "thread/list" }
        XCTAssertNotNil((lists.first?["params"] as? [String: Any])?["cwd"])
        XCTAssertNil((lists.last?["params"] as? [String: Any])?["cwd"])
    }

    func testClaudeDecodesOnlyTheRevealedPageAndSearchReachesOlderMetadata() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        for number in 1...40 { try claude(root: root, number: number, title: number == 40 ? "Older needle" : "Recent \(number)", modified: 10_000) }
        var reader = ClaudeHistoryReader()
        let first = reader.page(root: root, query: HistoryQuery(limit: 5))
        XCTAssertEqual(first.conversations.map(\.id.sessionID), (1...5).map(id))
        XCTAssertEqual(reader.cache.count, 5); XCTAssertNotNil(first.nextCursor)
        let second = reader.page(root: root, query: HistoryQuery(limit: 10), cursor: first.nextCursor)
        XCTAssertEqual(second.conversations.map(\.id.sessionID), (6...15).map(id))
        XCTAssertEqual(reader.cache.count, 15)
        let search = reader.page(root: root, query: HistoryQuery(search: "needle", limit: 10))
        XCTAssertEqual(search.conversations.map(\.id.sessionID), [id(40)])
        XCTAssertEqual(reader.cache.count, 40)
    }

    func testClaudeSearchContinuesAfterItsMetadataReadBudget() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        for number in 1...300 { try claude(root: root, number: number, title: number == 300 ? "Older needle" : "Recent \(number)", modified: Double(10_000 - number)) }
        var reader = ClaudeHistoryReader()
        let query = HistoryQuery(search: "needle", limit: 10)
        let first = reader.page(root: root, query: query)
        XCTAssertTrue(first.conversations.isEmpty); XCTAssertTrue(first.truncated); XCTAssertNotNil(first.nextCursor)
        let second = reader.page(root: root, query: query, cursor: first.nextCursor)
        XCTAssertEqual(second.conversations.map(\.id.sessionID), [id(300)])
        XCTAssertNil(second.nextCursor)
    }

    func testIncompleteClaudeManifestReportsTheOlderHistoryLimit() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        for number in 1...3 { try claude(root: root, number: number, title: "Conversation \(number)", modified: Double(10_000 - number)) }
        var reader = ClaudeHistoryReader()
        let result = reader.read(root: root, limit: 1)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.issues.contains { $0.message.contains("older conversations") && $0.message.contains("limit") })
    }

    func testLegacyFixtureAdapterPagesTheSameSortedMetadata() async throws {
        let entries = (1...25).map {
            ConversationMetadata(id: ConversationID(provider: .codex, sessionID: id($0)), title: "Conversation \($0)",
                directory: "/tmp/project", updatedAt: Date(timeIntervalSince1970: Double(100 - $0)))
        }
        let fixture: any SessionCatalogReading = SnapshotPageFixture(entries: entries)
        let first = await fixture.page(query: HistoryQuery(limit: 5))
        let second = await fixture.page(query: HistoryQuery(limit: 10, cursor: first.nextCursor))
        XCTAssertEqual(first.conversations.map(\.id.sessionID), (1...5).map(id))
        XCTAssertEqual(second.conversations.map(\.id.sessionID), (6...15).map(id))
    }

    func testCatalogMergesProviderPagesWithoutDuplicatesOrFullInventory() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try codex(root: root, rows: (1...20).map { row($0, directory: root.path, updated: Double(10_000 - $0 * 2)) })
        let claudeRoot = root.appendingPathComponent("claude")
        for number in 1...20 { try claude(root: claudeRoot, number: number, title: "Claude \(number)", modified: Double(10_001 - number * 2)) }
        let catalog = SessionCatalog(resolver: PageResolver(executable: fixture.0), environment: fixture.1, claudeRoot: claudeRoot)
        var cursor: String?, observed: [ConversationMetadata] = []
        for _ in 0..<4 {
            let page = await catalog.page(query: HistoryQuery(limit: 5, cursor: cursor))
            XCTAssertEqual(page.conversations.count, 5)
            observed += page.conversations; cursor = page.nextCursor
        }
        XCTAssertEqual(observed.count, Set(observed.map(\.id)).count)
        XCTAssertEqual(observed, observed.sorted(by: historyNewestFirst))
        let list = try requests(fixture.2).filter { $0["method"] as? String == "thread/list" }
        XCTAssertLessThan(list.reduce(0) { $0 + (($1["params"] as? [String: Any])?["limit"] as? Int ?? 0) }, 20)
        let mismatch = await catalog.page(query: HistoryQuery(search: "other", cursor: cursor))
        XCTAssertTrue(mismatch.conversations.isEmpty); XCTAssertFalse(mismatch.issues.isEmpty)
    }

    func testOneInvalidationRefreshesProviderPagesAndTheClaudeFileIndex() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try codex(root: root, rows: [row(1, directory: root.path, title: "Original Codex", updated: 10_000)])
        let claudeRoot = root.appendingPathComponent("claude")
        try claude(root: claudeRoot, number: 2, title: "Original Claude", modified: 9_999)
        let catalog = SessionCatalog(resolver: PageResolver(executable: fixture.0), environment: fixture.1, claudeRoot: claudeRoot)
        let query = HistoryQuery(limit: 2)
        let original = await catalog.page(query: query)
        XCTAssertEqual(original.conversations.compactMap(\.title), ["Original Codex", "Original Claude"])
        try JSONSerialization.data(withJSONObject: [row(1, directory: root.path, title: "Renamed Codex", updated: 10_000)])
            .write(to: root.appendingPathComponent("rows.json"))
        try claude(root: claudeRoot, number: 2, title: "Renamed Claude", modified: 10_001)
        let cached = await catalog.page(query: query)
        XCTAssertEqual(cached.conversations, original.conversations)
        await catalog.invalidatePages()
        let refreshed = await catalog.page(query: query)
        XCTAssertEqual(refreshed.conversations.compactMap(\.title), ["Renamed Claude", "Renamed Codex"])
    }
}

private struct PageResolver: ExecutableResolver {
    let executable: String
    func resolve(_ tool: SessionTool, directory: String, prompt: String?) async throws -> LaunchSpec {
        try LaunchSpec(tool: tool, executable: executable, directory: directory)
    }
}

private struct SnapshotPageFixture: SessionCatalogReading {
    let entries: [ConversationMetadata]
    func refresh(force: Bool) async -> SessionCatalogSnapshot { SessionCatalogSnapshot(conversations: entries) }
}

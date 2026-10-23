import XCTest
import SpookkyCore
import SpookkyRuntime
@testable import SpookkyWorkspace

final class InstalledSessionCatalogTests: XCTestCase {
    private let first = "00000000-0000-4000-8000-000000000001"
    private let second = "00000000-0000-4000-8000-000000000002"
    private func temporary() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/spookky-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}



@MainActor final class HistoryResumeTests: XCTestCase {
}

extension InstalledSessionCatalogTests {
    func testInstalledCodexExternalMetadataLifecycleWhenRequested() throws {
        guard let executable = ProcessInfo.processInfo.environment["SPOOKKY_HISTORY_CODEX"] else { throw XCTSkip("Opt-in installed metadata probe uses an unreachable loopback provider. No model service is called.") }
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("provider"), checkout = root.appendingPathComponent("checkout")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CODEX_") }
        environment["PWD"] = checkout.path
        environment["CODEX_HOME"] = home.path
        environment["SPOOKKY_FIXTURE_CODEX"] = executable; environment["SPOOKKY_FIXTURE_CHECKOUT"] = checkout.path
        let script = #"""
import json, os, subprocess, time
p = subprocess.Popen([os.environ['SPOOKKY_FIXTURE_CODEX'], 'app-server'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, cwd=os.environ['SPOOKKY_FIXTURE_CHECKOUT'])
def send(v):
    p.stdin.write(json.dumps(v)+'\n'); p.stdin.flush()
def request(i, method, params):
    send(dict(id=i, method=method, params=params))
    while True:
        v=json.loads(p.stdout.readline())
        if v.get('id') == i:
            if 'error' in v: raise RuntimeError('fixture metadata RPC failed: '+json.dumps(v['error']))
            return v['result']
try:
    request(1,'initialize',dict(clientInfo=dict(name='spookky_external_fixture',version='1')))
    send(dict(method='initialized',params={}))
    result=request(2,'thread/start',dict(cwd=os.environ['SPOOKKY_FIXTURE_CHECKOUT'], modelProvider='spookky_fixture',model='fixture',config={'model_providers':{'spookky_fixture':{'name':'Offline history fixture','base_url':'http://127.0.0.1:9/v1','wire_api':'responses','requires_openai_auth':False,'request_max_retries':0,'stream_max_retries':0}}}))
    sid=result['thread']['id']
    request(3,'turn/start',dict(threadId=sid,cwd=os.environ['SPOOKKY_FIXTURE_CHECKOUT'],input=[dict(type='text',text='Disposable offline history fixture')]))
    history_path=result['thread'].get('path')
    deadline=time.monotonic()+5
    while True:
        records=[]
        if history_path and os.path.isfile(history_path):
            with open(history_path,'rb') as history:
                for line in history.read(32768).splitlines():
                    try: records.append(json.loads(line))
                    except (ValueError,UnicodeDecodeError): pass
        if any(row.get('type')=='session_meta' and row.get('payload',{}).get('id')==sid for row in records): break
        if time.monotonic()>=deadline: raise RuntimeError('fixture rollout metadata did not become readable before naming')
        time.sleep(.01)
    request(4,'thread/name/set',dict(threadId=sid,name='Disposable external title'))
    for attempt in range(20):
        page=request(10+attempt,'thread/list',dict(useStateDbOnly=True,modelProviders=[],sourceKinds=['vscode','cli','appServer','exec','unknown']))
        if any(row['id']==sid for row in page['data']): break
        time.sleep(.05)
    print(json.dumps(dict(id=sid,started=result['thread']['cwd'],listed=next(row['cwd'] for row in page['data'] if row['id']==sid))))
finally:
    p.stdin.close()
    try: p.wait(timeout=5)
    except subprocess.TimeoutExpired: p.terminate(); p.wait(timeout=5)
"""#
        let created = try ProcessRunner.run("/usr/bin/python3", ["-c", script], timeout: 20, environment: environment)
        XCTAssertEqual(created.status, 0, "Disposable app-server metadata fixture failed: " + String(created.error.prefix(2_048)))
        guard created.status == 0 else { return }
        let fixture = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(created.output.utf8)) as? [String: String])
        let id = try XCTUnwrap(fixture["id"])
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(fixture["started"], checkout.path)
        XCTAssertEqual(fixture["listed"], fixture["started"])
        let page = try CodexHistoryReader.page(executable: executable, environment: environment,
            query: HistoryQuery(directories: [checkout.path], search: "Disposable external", limit: 5,
                exactDirectories: true, titleSearchOnly: true))
        XCTAssertEqual(page.conversations.map(\.id.sessionID), [id])
        XCTAssertNil(page.nextCursor)
        let snapshot = try CodexHistoryReader.read(executable: executable, environment: environment)
        let item = try XCTUnwrap(snapshot.conversations.first { $0.id.sessionID == id })
        XCTAssertEqual(item.title, "Disposable external title")
        XCTAssertEqual(item.directory, fixture["listed"])
        let afterRestart = try CodexHistoryReader.read(executable: executable, environment: environment)
        XCTAssertEqual(afterRestart.conversations.first?.id, item.id)
        XCTAssertEqual(afterRestart.conversations.first?.title, item.title)
    }
    func testRepresentativeMetadataInventoryWhenRequested() throws {
        guard let executable = ProcessInfo.processInfo.environment["SPOOKKY_HISTORY_INVENTORY"] else { throw XCTSkip("Opt-in read-only metadata inventory") }
        let started = ProcessInfo.processInfo.systemUptime
        let codex = try CodexHistoryReader.read(executable: executable, environment: ProcessInfo.processInfo.environment)
        let codexTime = ProcessInfo.processInfo.systemUptime - started
        var claude = ClaudeHistoryReader()
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let cold = ProcessInfo.processInfo.systemUptime
        let first = claude.read(root: root)
        let coldTime = ProcessInfo.processInfo.systemUptime - cold
        let warm = ProcessInfo.processInfo.systemUptime
        let second = claude.read(root: root)
        let warmTime = ProcessInfo.processInfo.systemUptime - warm
        print("METADATA INVENTORY codex_count=\(codex.conversations.count) codex_ms=\(Int(codexTime * 1000)) codex_truncated=\(codex.truncated) claude_count=\(first.conversations.count) claude_cold_ms=\(Int(coldTime * 1000)) claude_warm_ms=\(Int(warmTime * 1000)) claude_truncated=\(second.truncated)")
    }
}

extension HistoryResumeTests {
}

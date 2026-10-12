import Foundation
import Testing
import SpookkyCore

struct AppPathsTests {
    @Test func productionIgnoresFixtureOverrides() {
        let paths = AppPaths(bundleID: "dev.spookky.app", home: URL(fileURLWithPath: "/home/example"), userID: 501,
                             environment: ["SPOOKKY_M1_DATA": "/tmp/fixture", "SPOOKKY_M1_ROOT": "/tmp/runtime"])
        #expect(paths.production)
        #expect(paths.data.path == "/home/example/Library/Application Support/Spookky")
        #expect(paths.runtime.path == "/tmp/spookky-app-501")
    }
    @Test func developmentRemainsSeparate() {
        let paths = AppPaths(bundleID: "dev.spookky.m0", home: URL(fileURLWithPath: "/home/example"), userID: 501, environment: [:])
        #expect(!paths.production)
        #expect(paths.data.lastPathComponent == "Development")
        #expect(paths.runtime.path == "/tmp/spookky-m1-501")
    }
    @Test func developmentFixturesRemainIsolated() {
        let paths = AppPaths(bundleID: nil, home: URL(fileURLWithPath: "/home/example"), userID: 501,
                             environment: ["SPOOKKY_M1_DATA": "/tmp/fixture", "SPOOKKY_M1_ROOT": "/tmp/runtime"])
        #expect(paths.data.path == "/tmp/fixture")
        #expect(paths.runtime.path == "/tmp/runtime")
    }
}

import Foundation
import XCTest
import SpookkyTestSupport
import SpookkyCore

final class AppPathsTests: XCTestCase {
    func testWorktreesAndProductionOwnDifferentState() {
        let home = URL(fileURLWithPath: "/home/example")
        let first = AppPaths(bundleID: "dev.spookky.m0", home: home, userID: 501, environment: [:], developmentCheckout: "/tmp/checkout-one")
        let second = AppPaths(bundleID: "dev.spookky.m0", home: home, userID: 501, environment: [:], developmentCheckout: "/tmp/checkout-two")
        let production = AppPaths(bundleID: "dev.spookky.app", home: home, userID: 501, environment: [:], developmentCheckout: "/tmp/checkout-one")
        expectTrue(first.data != second.data)
        expectTrue(first.runtime != second.runtime)
        expectTrue(first.data != production.data)
        expectTrue(first.runtime != production.runtime)
        expectTrue(production.developmentID == nil)
        let rebuilt = AppPaths(bundleID: "dev.spookky.development.example", home: home, userID: 501, environment: [:], developmentCheckout: "/tmp/checkout-one")
        expectTrue(first.data == rebuilt.data)
        expectTrue(first.runtime == rebuilt.runtime)
    }

    func testWorktreeFixturesCanStillOverrideTheirRoots() {
        let paths = AppPaths(bundleID: "dev.spookky.m0", home: URL(fileURLWithPath: "/home/example"), userID: 501,
                             environment: ["SPOOKKY_M1_DATA": "/tmp/fixture", "SPOOKKY_M1_ROOT": "/tmp/runtime"],
                             developmentCheckout: "/tmp/checkout-one")
        expectTrue(paths.data.path == "/tmp/fixture")
        expectTrue(paths.runtime.path == "/tmp/runtime")
    }
    func testProductionIgnoresFixtureOverrides() {
        let paths = AppPaths(bundleID: "dev.spookky.app", home: URL(fileURLWithPath: "/home/example"), userID: 501,
                             environment: ["SPOOKKY_M1_DATA": "/tmp/fixture", "SPOOKKY_M1_ROOT": "/tmp/runtime"])
        expectTrue(paths.production)
        expectTrue(paths.data.path == "/home/example/Library/Application Support/Spookky")
        expectTrue(paths.runtime.path == "/tmp/spookky-app-501")
    }
    func testDevelopmentRemainsSeparate() {
        let paths = AppPaths(bundleID: "dev.spookky.m0", home: URL(fileURLWithPath: "/home/example"), userID: 501, environment: [:])
        expectTrue(!paths.production)
        expectTrue(paths.data.lastPathComponent == "Development")
        expectTrue(paths.runtime.path == "/tmp/spookky-m1-501")
    }
    func testDevelopmentFixturesRemainIsolated() {
        let paths = AppPaths(bundleID: nil, home: URL(fileURLWithPath: "/home/example"), userID: 501,
                             environment: ["SPOOKKY_M1_DATA": "/tmp/fixture", "SPOOKKY_M1_ROOT": "/tmp/runtime"])
        expectTrue(paths.data.path == "/tmp/fixture")
        expectTrue(paths.runtime.path == "/tmp/runtime")
    }
}

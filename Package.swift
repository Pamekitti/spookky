// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpookkyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpookkyCore", targets: ["SpookkyCore"]),
        .library(name: "SpookkyFiles", targets: ["SpookkyFiles"]),
        .library(name: "SpookkySyntax", targets: ["SpookkySyntax"]),
        .library(name: "SpookkyGit", targets: ["SpookkyGit"]),
        .library(name: "SpookkyRuntime", targets: ["SpookkyRuntime"]),
        .library(name: "SpookkyWorkspace", targets: ["SpookkyWorkspace"]),
        .library(name: "SpookkyPersistence", targets: ["SpookkyPersistence"]),
        .executable(name: "spookky-launch", targets: ["SpookkyLaunch"]),
        .executable(name: "spookky-runtime-check", targets: ["SpookkyRuntimeCheck"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(path: "Dependencies/HighlighterSwift")
    ],
    targets: [
        .target(name: "SpookkyCore"),
        .target(name: "SpookkyFiles"),
        .target(name: "SpookkySyntax", dependencies: [.product(name: "Highlighter", package: "HighlighterSwift")]),
        .target(name: "SpookkyRuntime", dependencies: ["SpookkyCore"]),
        .target(name: "SpookkyGit", dependencies: ["SpookkyCore", "SpookkyFiles"]),
        .target(name: "SpookkyWorkspace", dependencies: ["SpookkyCore", "SpookkyRuntime", "SpookkyGit"]),
        .target(name: "SpookkyPersistence", dependencies: ["SpookkyCore", "SpookkyWorkspace", .product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "SpookkyLaunch", dependencies: ["SpookkyCore", "SpookkyRuntime"]),
        .executableTarget(name: "SpookkyRuntimeCheck", dependencies: ["SpookkyCore", "SpookkyRuntime"]),
        .testTarget(name: "SpookkyRuntimeTests", dependencies: ["SpookkyCore", "SpookkyRuntime", "SpookkyWorkspace", "SpookkyPersistence", "SpookkyGit", "SpookkyFiles", "SpookkySyntax"])
    ]
)

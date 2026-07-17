// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexSessionMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SessionMonitorCore", targets: ["SessionMonitorCore"]),
        .executable(name: "codex-session-monitor", targets: ["CodexSessionMonitor"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite3", path: "Sources/CSQLite3"),
        .target(name: "SessionMonitorCore", dependencies: ["CSQLite3"]),
        .executableTarget(name: "CodexSessionMonitor", dependencies: ["SessionMonitorCore"]),
        .testTarget(
            name: "SessionMonitorCoreTests",
            dependencies: ["SessionMonitorCore", "CodexSessionMonitor"],
            resources: [.copy("Fixtures")]
        ),
    ]
)

// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DontSleep",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DontSleepCore", targets: ["DontSleepCore"]),
        .library(name: "DontSleepPlatform", targets: ["DontSleepPlatform"]),
        .library(name: "DontSleepIPC", targets: ["DontSleepIPC"]),
        .executable(name: "DontSleepApp", targets: ["DontSleepApp"]),
        .executable(name: "DontSleepController", targets: ["DontSleepController"]),
        .executable(name: "DontSleepWatchdog", targets: ["DontSleepWatchdog"])
    ],
    targets: [
        .target(name: "DontSleepCore"),
        .testTarget(name: "DontSleepCoreTests", dependencies: ["DontSleepCore"]),
        .target(name: "DontSleepPlatform"),
        .testTarget(name: "DontSleepPlatformTests", dependencies: ["DontSleepPlatform"]),
        .target(name: "DontSleepIPC", dependencies: ["DontSleepCore", "DontSleepPlatform"]),
        .testTarget(name: "DontSleepIPCTests", dependencies: ["DontSleepIPC"]),
        .executableTarget(name: "DontSleepApp", dependencies: ["DontSleepCore", "DontSleepIPC", "DontSleepPlatform"]),
        .testTarget(name: "DontSleepAppTests", dependencies: ["DontSleepApp"]),
        .executableTarget(name: "DontSleepController", dependencies: ["DontSleepIPC"]),
        .executableTarget(name: "DontSleepWatchdog", dependencies: ["DontSleepIPC"])
    ]
)

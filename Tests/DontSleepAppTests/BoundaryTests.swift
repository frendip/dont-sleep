import XCTest
@testable import DontSleepApp

final class BoundaryTests: XCTestCase {
    func testSingleInstanceRejectsOtherMatchingAppButIgnoresSelfAndOtherProducts() {
        XCTAssertEqual(InstanceGate.existingPID(current: 100, bundleID: "local.dontsleep.app", processes: [(100, "local.dontsleep.app"), (101, "other.app"), (99, "local.dontsleep.app")]), 99)
        XCTAssertNil(InstanceGate.existingPID(current: 100, bundleID: "local.dontsleep.app", processes: [(100, "local.dontsleep.app")]))
        XCTAssertNil(InstanceGate.existingPID(current: 100, bundleID: nil, processes: [(99, nil)]))
    }
    func testInstanceLockAllowsOnlyOneLifetimeHolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("instance.lock")
        var first = try InstanceLock.acquire(at: path)
        XCTAssertNotNil(first)
        XCTAssertNil(try InstanceLock.acquire(at: path))
        first = nil
        let replacement = try InstanceLock.acquire(at: path)
        XCTAssertNotNil(replacement)
        withExtendedLifetime(replacement) {}
    }
    func testInstallerRejectsModifiedBytesBeforeProducingRootCommand() {
        XCTAssertThrowsError(try InstallerProgram.command(program: Data("changed".utf8), digest: "a75d3524c5a87e87c6024fae1f66d58f12eaf7472eaf3dd87cc6b18f52c77e89", appPath: "/Applications/App.app", uid: 501, liveHash: "abcd"))
    }
    func testCapturedInstallerPreservesLiteralPathAndCannotExpandShellInput() throws {
        let bytes = Data("printf '%s' \"$1\"".utf8)
        let command = try InstallerProgram.command(program: bytes, digest: "951ffd9f545137425bc13dccc96f679a41922308c0aa32a0f021ef46fabdd0ef", appPath: "/Applications/Don't $(printf BAD).app", uid: 501, liveHash: "abcd")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = ["-c", command]
        let output = Pipe(); process.standardOutput = output
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), "/Applications/Don't $(printf BAD).app")
    }
}

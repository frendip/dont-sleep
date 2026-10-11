import XCTest
import Darwin
@testable import DontSleepPlatform
final class ProcessTests: XCTestCase {
 func testUnreapedTimeoutRejectsNewCommandThenRecoversOnlyAfterReap() throws {
  let observation = DelayedReapObservation()
  defer { observation.cleanUp() }
  let runner = BoundedProcess(timeout: 0.01, observation: observation)
  XCTAssertThrowsError(try runner.runProgram(path: "/usr/bin/true", arguments: [], inheritingLockFD: nil)) { XCTAssertEqual($0 as? PlatformError, .childNotReaped) }
  let retainedPID = try XCTUnwrap(observation.delayedPID)
  XCTAssertThrowsError(try runner.runProgram(path: "/does-not-exist", arguments: [], inheritingLockFD: nil)) { XCTAssertEqual($0 as? PlatformError, .childNotReaped) }
  XCTAssertEqual(observation.distinctPIDs, [retainedPID])
  observation.allowReap = true
  let result = try runner.runProgram(path: "/usr/bin/printf", arguments: ["new-command"], inheritingLockFD: nil)
  XCTAssertEqual(result.exitCode, 0)
  XCTAssertEqual(String(data: result.output, encoding: .utf8), "new-command")
  XCTAssertTrue(observation.didReapDelayedChild)
 }
 func testLostOwnershipNeverSignalsOrSpawnsAgain() throws {
  let observation = DelayedReapObservation()
  defer { observation.cleanUp() }
  let runner = BoundedProcess(timeout: 0.01, observation: observation)
  XCTAssertThrowsError(try runner.runProgram(path: "/usr/bin/true", arguments: [], inheritingLockFD: nil))
  observation.reportOwnershipLost = true
  let signals = observation.signalCount
  XCTAssertThrowsError(try runner.runProgram(path: "/usr/bin/printf", arguments: ["must-not-run"], inheritingLockFD: nil)) { XCTAssertEqual($0 as? PlatformError, .childNotReaped) }
  observation.reportOwnershipLost = false; observation.allowReap = true
  XCTAssertThrowsError(try runner.runProgram(path: "/usr/bin/printf", arguments: ["still-must-not-run"], inheritingLockFD: nil)) { XCTAssertEqual($0 as? PlatformError, .childNotReaped) }
  XCTAssertEqual(observation.signalCount, signals)
  XCTAssertEqual(observation.distinctPIDs.count, 1)
 }

 func testTimeoutReapsChildBeforeReturningAndNextCallWorks() throws {
  let runner = BoundedProcess(timeout: 0.05)
  XCTAssertThrowsError(try runner.runProgram(path: "/bin/sleep", arguments: ["10"], inheritingLockFD: nil)) { XCTAssertEqual($0 as? PlatformError, .timedOut) }
  let result = try runner.runProgram(path: "/usr/bin/true", arguments: [], inheritingLockFD: nil)
  XCTAssertEqual(result.exitCode, 0)
 }
 func testCapturesOutputAndFailureWithoutShell() throws {
  let runner = BoundedProcess()
  let result = try runner.runProgram(path: "/usr/bin/printf", arguments: ["%s", "literal;$(whoami)"], inheritingLockFD: nil)
  XCTAssertEqual(String(data: result.output, encoding: .utf8), "literal;$(whoami)")
  XCTAssertEqual(try runner.runProgram(path: "/usr/bin/false", arguments: [], inheritingLockFD: nil).exitCode, 1)
 }
 func testChildExplicitlyInheritsLockDespiteCloseOnExecDefault() throws {
  let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  let lock = try WriterLock(directory: directory, expectedOwner: getuid()); try lock.acquire()
  let result = try BoundedProcess().runProgram(path: "/bin/sh", arguments: ["-c", "if [ -e /dev/fd/198 ]; then printf inherited; else exit 9; fi"], inheritingLockFD: lock.descriptor)
  XCTAssertEqual(result.exitCode, 0)
  XCTAssertEqual(String(data: result.output, encoding: .utf8), "inherited")
 }
 func testChildKeepsWriterLockAfterOwnerDescriptorCloses() throws {
  let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  defer { try? FileManager.default.removeItem(at: directory) }
  var owner: WriterLock? = try WriterLock(directory: directory, expectedOwner: getuid())
  try owner!.acquire()
  let inheritedFD = owner!.descriptor
  let ready = directory.appendingPathComponent("child-ready")
  let release = directory.appendingPathComponent("child-release")
  let completed = expectation(description: "harmless child reaped")
  DispatchQueue.global().async {
   defer { completed.fulfill() }
   do {
    let result = try BoundedProcess(timeout: 5).runProgram(path: "/bin/sh", arguments: ["-c",
      "printf ready > \"$1\"; while [ ! -e \"$2\" ]; do /bin/sleep 0.02; done", "lock-test", ready.path, release.path], inheritingLockFD: inheritedFD)
    XCTAssertEqual(result.exitCode, 0)
   } catch { XCTFail("Child fixture failed: \(error)") }
  }
  let deadline = Date().addingTimeInterval(3)
  while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
  let childStarted = FileManager.default.fileExists(atPath: ready.path)
  XCTAssertTrue(childStarted, "Child must inherit the descriptor before the owner closes it")
  if childStarted {
   owner = nil // Closing the owner's last descriptor models its process death.
   let replacement = try WriterLock(directory: directory, expectedOwner: getuid())
   XCTAssertThrowsError(try replacement.acquire()) { XCTAssertEqual($0 as? PlatformError, .writerBusy) }
   try Data().write(to: release)
   wait(for: [completed], timeout: 6)
   XCTAssertNoThrow(try replacement.acquire(), "Only child exit may release the inherited lock")
   replacement.release()
  } else {
   try Data().write(to: release)
   wait(for: [completed], timeout: 6)
  }
 }
 func testRealPowerWriterRefusesMissingLock() {
  XCTAssertThrowsError(try BoundedProcess().run(.setDisabled(true), inheritingLockFD: nil)) { XCTAssertEqual($0 as? PlatformError, .writerNotHeld) }
 }
}

/// Only the observation of one harmless real child is delayed. Its PID remains
/// owned/unreaped until an explicit waitpid confirms termination; no fake PID is
/// ever signalled. Virtual time reproduces a kernel-delayed exit without a hang.
private final class DelayedReapObservation: ProcessObservationDriver {
 var delayedPID: pid_t?
 var distinctPIDs = Set<pid_t>()
 var allowReap = false
 var reportOwnershipLost = false
 var didReapDelayedChild = false
 var signalCount = 0
 var time: UInt64 = 0
 func observe(_ pid: pid_t) -> ChildObservation {
  distinctPIDs.insert(pid)
  if delayedPID == nil { delayedPID = pid }
  if pid == delayedPID && !didReapDelayedChild {
   if reportOwnershipLost { return .ownershipLost }
   if !allowReap { return .running }
   var status: Int32 = 0
   guard waitpid(pid, &status, 0) == pid else { return .ownershipLost }
   didReapDelayedChild = true
   return .exited(status)
  }
  var status: Int32 = 0
  let result = waitpid(pid, &status, WNOHANG)
  if result == pid { return .exited(status) }
  if result == 0 { return .running }
  return errno == EINTR ? .interrupted : .ownershipLost
 }
 func signal(_ pid: pid_t, _ signal: Int32) { signalCount += 1 }
 func nanoseconds() -> UInt64 { time }
 func pause() {
  if didReapDelayedChild { usleep(1_000) }
  else { time += 1_000_000_000; usleep(1_000) }
 }
 func cleanUp() {
  if let pid = delayedPID, !didReapDelayedChild {
   var status: Int32 = 0
   _ = waitpid(pid, &status, 0)
  }
 }
}

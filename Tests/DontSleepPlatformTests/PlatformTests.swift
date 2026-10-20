import XCTest
import Darwin
@testable import DontSleepPlatform

final class JournalTests: XCTestCase {
 func temporary() throws -> URL {
  let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  addTeardownBlock { try? FileManager.default.removeItem(at: url) }
  return url
 }
 func record() -> RecoveryRecord { RecoveryRecord(sessionID: UUID(), generation: 1, bootID: "test-boot", phase: .prepared, original: SleepSnapshot(actualDisabled: false, persistedDisabled: false)) }
 func testDurableRoundTripAndMatchingCompletion() throws {
  let directory = try temporary(); let first = try RecoveryJournal(directory: directory, expectedOwner: getuid())
  XCTAssertNil(try first.load())
  let original = record(); try first.persist(original)
  let reopened = try RecoveryJournal(directory: directory, expectedOwner: getuid())
  XCTAssertEqual(try reopened.load(), original)
  XCTAssertThrowsError(try reopened.markRestored(sessionID: UUID()))
  XCTAssertEqual(try reopened.load()?.phase, .prepared)
  try reopened.markRestored(sessionID: original.sessionID)
  XCTAssertEqual(try reopened.load()?.phase, .restored)
 }
 func testCorruptJournalDoesNotBecomeNoSession() throws {
  let directory = try temporary(); let journal = try RecoveryJournal(directory: directory, expectedOwner: getuid())
  try Data("broken".utf8).write(to: directory.appendingPathComponent("recovery.json"))
  chmod(directory.appendingPathComponent("recovery.json").path, 0o600)
  XCTAssertThrowsError(try journal.load())
 }
 func testSymlinkAndWritableDirectoryAreRejected() throws {
  let directory = try temporary(); let linked = directory.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: directory)
  XCTAssertThrowsError(try RecoveryJournal(directory: linked, expectedOwner: getuid()))
  chmod(directory.path, 0o777)
  XCTAssertThrowsError(try RecoveryJournal(directory: directory, expectedOwner: getuid()))
 }
 func testWrongOwnerAndHardlinkedJournalRejected() throws {
  let directory = try temporary()
  XCTAssertThrowsError(try RecoveryJournal(directory: directory, expectedOwner: getuid() + 1))
  let journal = try RecoveryJournal(directory: directory, expectedOwner: getuid()); try journal.persist(record())
  try FileManager.default.linkItem(at: directory.appendingPathComponent("recovery.json"), to: directory.appendingPathComponent("alias"))
  XCTAssertThrowsError(try journal.load())
 }
 func testUnfinishedRecordCannotBeOverwrittenByAnotherSession() throws {
  let journal = try RecoveryJournal(directory: temporary(), expectedOwner: getuid())
  try journal.persist(record())
  XCTAssertThrowsError(try journal.persist(record()))
 }
 func testInterruptedTemporaryWritePreservesLastCompleteRecord() throws {
  let directory = try temporary(); let journal = try RecoveryJournal(directory: directory, expectedOwner: getuid())
  let original = record(); try journal.persist(original)
  try Data("{\"version\":1,".utf8).write(to: directory.appendingPathComponent(".journal-interrupted"))
  XCTAssertEqual(try RecoveryJournal(directory: directory, expectedOwner: getuid()).load(), original)
 }
 func testFutureSchemaAndRewrittenBaselineAreRejected() throws {
  let directory = try temporary(); let journal = try RecoveryJournal(directory: directory, expectedOwner: getuid())
  var original = record(); try journal.persist(original)
  var data = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("recovery.json"))) as! [String: Any]
  data["version"] = 999
  try JSONSerialization.data(withJSONObject: data).write(to: directory.appendingPathComponent("recovery.json"))
  XCTAssertThrowsError(try journal.load())
  data["version"] = 1
  try JSONSerialization.data(withJSONObject: data).write(to: directory.appendingPathComponent("recovery.json"))
  original.phase = .restoring; try journal.persist(original)
  original.phase = .active; XCTAssertThrowsError(try journal.persist(original))
 }
 func testStopReasonSurvivesCompletionAndRejectsUnboundedText() throws {
  let directory = try temporary(); let journal = try RecoveryJournal(directory: directory, expectedOwner: getuid())
  var original = record(); original.stopReason = "leaseExpired"
  try journal.persist(original); try journal.markRestored(sessionID: original.sessionID)
  XCTAssertEqual(try RecoveryJournal(directory: directory, expectedOwner: getuid()).load()?.stopReason, "leaseExpired")
  var invalid = record(); invalid.stopReason = String(repeating: "a", count: 65)
  XCTAssertThrowsError(try journal.persist(invalid))
  invalid.stopReason = "free text\n"
  XCTAssertThrowsError(try journal.persist(invalid))
 }
 func testOldJournalWithoutStopReasonRemainsReadable() throws {
  let directory = try temporary(); let journal = try RecoveryJournal(directory: directory, expectedOwner: getuid())
  let original = record(); try journal.persist(original)
  var data = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("recovery.json"))) as! [String: Any]
  data.removeValue(forKey: "stopReason")
  try JSONSerialization.data(withJSONObject: data).write(to: directory.appendingPathComponent("recovery.json"))
  XCTAssertNil(try journal.load()?.stopReason)
  XCTAssertEqual(try journal.load()?.sessionID, original.sessionID)
 }
 func testTwoWritersCannotAcquireSameLock() throws {
  let directory = try temporary()
  let first = try WriterLock(directory: directory, expectedOwner: getuid())
  let second = try WriterLock(directory: directory, expectedOwner: getuid())
  try first.acquire(); XCTAssertThrowsError(try second.acquire())
  first.release(); XCTAssertNoThrow(try second.acquire()); second.release()
 }
}

final class BackendTests: XCTestCase {
 func testPersistedParserRejectsAmbiguityAndUnexpectedValues() throws {
  XCTAssertEqual(try PMSetSleepBackend.parsePersisted("System-wide power settings:\n SleepDisabled\t\t0\nAC Power:\n sleep 1\n"), false)
  XCTAssertThrowsError(try PMSetSleepBackend.parsePersisted(" SleepDisabled 0\n SleepDisabled 1\n"))
  XCTAssertThrowsError(try PMSetSleepBackend.parsePersisted(" SleepDisabled 2\n"))
  XCTAssertThrowsError(try PMSetSleepBackend.parsePersisted("AC Power:\n sleep 1\n"))
 }
 // Real pmset -g output reported on macOS Tahoe 26.2, before disablesleep was set.
 static let unsetSettings = """
 System-wide power settings:
 Currently in use:
  standby              1
  Sleep On Power Button 1
  hibernatefile        /var/vm/sleepimage
  powernap             1
  networkoversleep     0
  disksleep            0
  sleep                1 (sleep prevented by sharingd, powerd, WhatsApp)
  hibernatemode        3
  ttyskeepawake        1
  displaysleep         0
  tcpkeepalive         1
  powermode            2
  womp                 0
 """
 func testUnsetPersistedSettingCanBeEnabledAndRestored() throws {
  let runner = StatefulRunner()
  let backend = PMSetSleepBackend(runner: runner, actualState: { runner.actualDisabled })
  let original = try backend.read()
  XCTAssertEqual(original, SleepSnapshot(actualDisabled: false, persistedDisabled: false))
  try backend.applyDisabled()
  XCTAssertEqual(try backend.read(), SleepSnapshot(actualDisabled: true, persistedDisabled: true))
  try backend.restore(original)
  XCTAssertTrue(try backend.verify(original))
  XCTAssertEqual(runner.writes, [true, false])
 }
 func testMissingSettingRequiresACompleteSystemSettingsSection() throws {
  for text in ["", "Currently in use:\n sleep 1\n", "System-wide power settings:\n",
               "System-wide power settings:\n SleepDisabled", "System-wide power settings:\nCurrently in use:\n",
               "Currently in use:\n sleep 1\nSystem-wide power settings:\n",
               "System-wide power settings:\n SleepDisabled: 0\nCurrently in use:\n sleep 1\n",
               "System-wide power settings:\nSystem-wide power settings:\nCurrently in use:\n sleep 1\n"] {
   XCTAssertThrowsError(try PMSetSleepBackend.parsePersisted(text), text)
  }
  XCTAssertFalse(try PMSetSleepBackend.parsePersisted("System-wide power settings:\n DestroyFVKeyOnStandby 0\n VACTDisabled 1\nCurrently in use:\n sleep 1\n"))
 }
 func testUnsetSettingDoesNotOverrideDisabledOrUnreadableActualState() {
  let runner = StatefulRunner()
  let disabled = PMSetSleepBackend(runner: runner, actualState: { true })
  XCTAssertThrowsError(try disabled.applyDisabled()) { XCTAssertEqual($0 as? PlatformError, .baselineDisabled) }
  let unreadable = PMSetSleepBackend(runner: runner, actualState: { throw PlatformError.invalidPowerState })
  XCTAssertThrowsError(try unreadable.applyDisabled())
  XCTAssertTrue(runner.writes.isEmpty)
 }
 func testUnsetSettingDoesNotConfirmApplicationWithoutBothReadbacks() {
  for updatesActual in [false, true] {
   let runner = StatefulRunner()
   runner.updatesActual = updatesActual
   runner.updatesPersisted = !updatesActual
   let backend = PMSetSleepBackend(runner: runner, actualState: { runner.actualDisabled })
   XCTAssertThrowsError(try backend.applyDisabled()) { XCTAssertEqual($0 as? PlatformError, .verificationFailed) }
   XCTAssertEqual(runner.writes, [true])
  }
 }
 func testRestorationFromUnsetBaselineRequiresBothReadbacks() throws {
  for updatesActual in [false, true] {
   let runner = StatefulRunner()
   let backend = PMSetSleepBackend(runner: runner, actualState: { runner.actualDisabled })
   let original = try backend.read()
   try backend.applyDisabled()
   runner.updatesActual = updatesActual
   runner.updatesPersisted = !updatesActual
   XCTAssertThrowsError(try backend.restore(original)) { XCTAssertEqual($0 as? PlatformError, .verificationFailed) }
   XCTAssertFalse(try backend.verify(original))
  }
 }
 final class StatefulRunner: SystemCommandRunning {
  var actualDisabled = false
  var persistedDisabled: Bool?
  var updatesActual = true
  var updatesPersisted = true
  var writes: [Bool] = []
  func run(_ command: PowerCommand, inheritingLockFD: Int32?) throws -> CommandResult {
   switch command {
   case .readSettings:
    let text: String
    if let persistedDisabled {
     text = "System-wide power settings:\n SleepDisabled \(persistedDisabled ? 1 : 0)\nCurrently in use:\n sleep 1\n"
    } else { text = BackendTests.unsetSettings }
    return CommandResult(exitCode: 0, output: Data(text.utf8))
   case .setDisabled(let disabled):
    writes.append(disabled)
    if updatesActual { actualDisabled = disabled }
    if updatesPersisted { persistedDisabled = disabled }
    return CommandResult(exitCode: 0, output: Data())
   }
  }
 }
 func testExistingDisabledStateIsNeverAdopted() {
  XCTAssertThrowsError(try SleepSnapshot(actualDisabled: true, persistedDisabled: false).validateBaseline())
  XCTAssertThrowsError(try SleepSnapshot(actualDisabled: false, persistedDisabled: true).validateBaseline())
  XCTAssertNoThrow(try SleepSnapshot(actualDisabled: false, persistedDisabled: false).validateBaseline())
 }
 func testExitZeroDoesNotReplaceReadback() throws {
  let backend = PMSetSleepBackend(runner: FakeRunner(), actualState: { false })
  XCTAssertThrowsError(try backend.applyDisabled())
 }
 final class FakeRunner: SystemCommandRunning {
  func run(_ command: PowerCommand, inheritingLockFD: Int32?) throws -> CommandResult { CommandResult(exitCode: 0, output: Data("System-wide power settings:\n SleepDisabled 0\n".utf8)) }
 }
}

final class PowerTests: XCTestCase {
 func testMissingOrInvalidPowerIsUnknown() {
  XCTAssertEqual(NativePowerSample.decode(source: "Battery Power", current: 20, maximum: 100, at: 1).percent, 20)
  XCTAssertEqual(NativePowerSample.decode(source: "AC Power", current: 20, maximum: 100, at: 1).source, .ac)
  XCTAssertEqual(NativePowerSample.decode(source: "Battery Power", current: 21, maximum: 100, at: 1).percent, 21)
  XCTAssertEqual(NativePowerSample.decode(source: "UPS Power", current: 21, maximum: 100, at: 1).source, .unknown)
  XCTAssertNil(NativePowerSample.decode(source: "Battery Power", current: 101, maximum: 100, at: 1).percent)
  XCTAssertEqual(NativePowerSample.decode(source: "Battery Power", current: 20, maximum: 0, at: 1).source, .unknown)
 }
}

final class TrustTests: XCTestCase {
 func manifest(hash: String = String(repeating: "a", count: 40)) -> TrustManifest {
  let app = TrustedCode(identifier: "local.dontsleep.app", cdhash: hash)
  return TrustManifest(version: 1, authorizedUID: 501, app: app, controller: TrustedCode(identifier: "local.dontsleep.controller", cdhash: String(repeating: "b", count: 40)), watchdog: TrustedCode(identifier: "local.dontsleep.watchdog", cdhash: String(repeating: "c", count: 40)))
 }
 func testMalformedPinsAreRejectedRatherThanInterpolated() {
  XCTAssertThrowsError(try TrustPolicy(manifest: manifest(hash: "abc\" or true")))
  XCTAssertThrowsError(try TrustPolicy(manifest: manifest(hash: "")))
  XCTAssertNoThrow(try TrustPolicy(manifest: manifest()))
 }
 func testUIDBoundaryRequiresInstalledUserOrRootService() throws {
  let trust = try TrustPolicy(manifest: manifest())
  XCTAssertTrue(trust.validateUID(501, role: .app))
  XCTAssertFalse(trust.validateUID(502, role: .app))
  XCTAssertFalse(trust.validateUID(501, role: .watchdog))
  XCTAssertTrue(trust.validateUID(0, role: .watchdog))
 }
}

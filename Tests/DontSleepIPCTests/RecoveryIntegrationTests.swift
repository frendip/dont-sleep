import XCTest
import DontSleepCore
import DontSleepPlatform
@testable import DontSleepIPC

final class RecoveryIntegrationTests: XCTestCase {
    final class Backend: SleepBackend {
        var snapshot = SleepSnapshot(actualDisabled: false, persistedDisabled: false)
        var applyCount = 0
        var restoreCount = 0
        var refuseRestore = false
        var beforeApply: (() throws -> Void)?
        func read() throws -> SleepSnapshot { snapshot }
        func applyDisabled() throws { try beforeApply?(); applyCount += 1; snapshot = SleepSnapshot(actualDisabled: true, persistedDisabled: true) }
        func restore(_ original: SleepSnapshot) throws { restoreCount += 1; if !refuseRestore { snapshot = original } }
        func verify(_ expected: SleepSnapshot) throws -> Bool { snapshot == expected }
    }
    func fixture() throws -> (URL, RecoveryJournal, Backend) {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (url, try RecoveryJournal(directory: url, expectedOwner: getuid()), Backend())
    }
    func testJournalPrecedesMutationAndExpiredLeaseRestores() throws {
        let (_, journal, backend) = try fixture()
        backend.beforeApply = { XCTAssertEqual(try journal.load()?.phase, .prepared) }
        let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "test")
        let power = PowerSnapshot(source: .battery, percent: 21, sampledAt: 100)
        _ = host.process(.health, now: 100, power: power)
        let active = host.process(.start(.fiveMinutes), now: 100, power: power)
        XCTAssertEqual(active.snapshot.state, .active)
        host.tick(now: 130, power: PowerSnapshot(source: .battery, percent: 21, sampledAt: 130))
        XCTAssertTrue(host.response(now: 130).snapshot.verifiedOff)
        XCTAssertEqual(backend.restoreCount, 1)
        XCTAssertEqual(try journal.load()?.phase, .restored)
    }
    func testFailedRestoreNeverClaimsOffAndCanRetry() throws {
        let (_, journal, backend) = try fixture()
        let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "test")
        let power = PowerSnapshot(source: .ac, percent: 10, sampledAt: 100)
        _ = host.process(.health, now: 100, power: power)
        _ = host.process(.start(.permanent), now: 100, power: power)
        backend.refuseRestore = true
        XCTAssertEqual(host.process(.stop, now: 101, power: power).snapshot.state, .failed)
        XCTAssertFalse(host.response(now: 101).snapshot.verifiedOff)
        backend.refuseRestore = false
        XCTAssertTrue(host.process(.stop, now: 102, power: power).snapshot.verifiedOff)
    }
    func testBootRecoveryRestoresAndDoesNotResume() throws {
        let (_, journal, backend) = try fixture()
        let original = backend.snapshot
        try journal.persist(RecoveryRecord(sessionID: UUID(), generation: 1, bootID: "previous", phase: .active, original: original))
        backend.snapshot = SleepSnapshot(actualDisabled: true, persistedDisabled: true)
        let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "next")
        XCTAssertTrue(host.response(now: 1).snapshot.verifiedOff)
        XCTAssertEqual(backend.applyCount, 0)
        XCTAssertEqual(backend.restoreCount, 1)
    }
    func testHealthDoesNotRenewUILeaseAndStaleHeartbeatDoesNotRevive() throws {
        let (_, journal, backend) = try fixture()
        let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "test")
        func p(_ t: UInt64) -> PowerSnapshot { .init(source: .ac, percent: 100, sampledAt: t) }
        _ = host.process(.health, now: 100, power: p(100))
        let active = host.process(.start(.permanent), now: 100, power: p(100))
        for t: UInt64 in [105,110,115,120,125,130] { _ = host.process(.health, now: t, power: p(t)) }
        XCTAssertTrue(host.response(now: 130).snapshot.verifiedOff)
        _ = host.process(.heartbeat(active.snapshot.session!.identity), now: 131, power: p(131))
        XCTAssertEqual(backend.applyCount, 1)
        XCTAssertTrue(host.response(now: 131).snapshot.verifiedOff)
    }
    func testControllerLossRestoresWithoutWaitingForUILease() throws {
        let (_, journal, backend) = try fixture()
        let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "test")
        let p = PowerSnapshot(source: .ac, percent: 100, sampledAt: 100)
        _ = host.process(.start(.permanent), now: 100, power: p)
        host.tick(now: 115, power: .init(source: .ac, percent: 100, sampledAt: 115))
        XCTAssertTrue(host.response(now: 115).snapshot.verifiedOff)
        XCTAssertEqual(backend.restoreCount, 1)
    }
    func testMaintenancePreventsQueuedStartsAndCannotBeClearedByHealth() throws {
        let (_, journal, backend) = try fixture()
        let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "test")
        let p = PowerSnapshot(source: .ac, percent: 100, sampledAt: 100)
        _ = host.process(.start(.permanent), now: 100, power: p)
        XCTAssertTrue(host.process(.maintenance, now: 101, power: p).snapshot.verifiedOff)
        _ = host.process(.health, now: 102, power: p)
        XCTAssertTrue(host.process(.start(.permanent), now: 103, power: p).snapshot.verifiedOff)
        XCTAssertEqual(backend.applyCount, 1)
    }
    func testAllUnfinishedJournalPhasesRecoverButRestoredDoesNotMutate() throws {
        for phase: RecoveryPhase in [.prepared, .active, .restoring, .restored] {
            let (_, journal, backend) = try fixture()
            let original = backend.snapshot
            try journal.persist(RecoveryRecord(sessionID: UUID(), generation: 7, bootID: "old", phase: phase, original: original))
            backend.snapshot = .init(actualDisabled: true, persistedDisabled: true)
            let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "new")
            XCTAssertTrue(host.response(now: 10).snapshot.verifiedOff)
            XCTAssertEqual(backend.restoreCount, phase == .restored ? 0 : 1)
            XCTAssertEqual(backend.applyCount, 0)
        }
    }
    func testBatteryCutoffAndRepeatedStopDoNotApplyAgain() throws {
        let (_, journal, backend) = try fixture()
        let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "test")
        let p = PowerSnapshot(source: .battery, percent: 21, sampledAt: 100)
        _ = host.process(.start(.permanent), now: 100, power: p)
        let low = PowerSnapshot(source: .battery, percent: 20, sampledAt: 101)
        XCTAssertTrue(host.process(.status, now: 101, power: low).snapshot.verifiedOff)
        _ = host.process(.stop, now: 101, power: low)
        _ = host.process(.start(.permanent), now: 101, power: low)
        XCTAssertEqual(backend.applyCount, 1)
        XCTAssertEqual(backend.restoreCount, 1)
    }

    func testFailedRestoreRetriesAtBoundedCadenceWithoutUI() throws {
        let (_, journal, backend) = try fixture()
        let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "test")
        let p = PowerSnapshot(source: .ac, percent: 100, sampledAt: 100)
        _ = host.process(.start(.permanent), now: 100, power: p)
        backend.refuseRestore = true
        _ = host.process(.stop, now: 101, power: p)
        XCTAssertEqual(backend.restoreCount, 1)
        host.tick(now: 130, power: .init(source: .ac, percent: 100, sampledAt: 130))
        XCTAssertEqual(backend.restoreCount, 1)
        backend.refuseRestore = false
        host.tick(now: 131, power: .init(source: .ac, percent: 100, sampledAt: 131))
        XCTAssertEqual(backend.restoreCount, 2)
        XCTAssertTrue(host.response(now: 131).snapshot.verifiedOff)
    }

    func testLeaseStopReasonSurvivesWriterRestart() throws {
        let (_, journal, backend) = try fixture()
        let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "test")
        _ = host.process(.start(.permanent), now: 100, power: .init(source: .ac, percent: 100, sampledAt: 100))
        for t: UInt64 in [105, 110, 115, 120, 125, 130] {
            _ = host.process(.health, now: t, power: .init(source: .ac, percent: 100, sampledAt: t))
        }
        XCTAssertEqual(host.response(now: 130).lastStopReason, .leaseExpired)
        XCTAssertEqual(try journal.load()?.stopReason, SessionIssue.leaseExpired.rawValue)
        let restarted = try RecoveryRuntime(backend: backend, journal: journal, bootID: "next", now: 200)
        XCTAssertTrue(restarted.response(now: 200).snapshot.verifiedOff)
        XCTAssertEqual(restarted.response(now: 200).lastStopReason, .leaseExpired)
        XCTAssertEqual(backend.applyCount, 1)
    }

}

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

    // Real journal reads/writes stay in the fixture; only the unavailable storage
    // operation is injected so this cannot touch the machine's power settings.
    final class FaultingJournal: RecoveryJournalStoring {
        let underlying: RecoveryJournal
        var refuseWrites = false
        var readOverride: (() throws -> RecoveryRecord?)?
        init(_ underlying: RecoveryJournal) { self.underlying = underlying }
        func load() throws -> RecoveryRecord? {
            if let readOverride { return try readOverride() }
            return try underlying.load()
        }
        func persist(_ record: RecoveryRecord) throws {
            if refuseWrites { throw PlatformError.system("test journal write", ENOSPC) }
            try underlying.persist(record)
        }
        func markRestored(sessionID: UUID) throws {
            if refuseWrites { throw PlatformError.system("test journal completion", ENOSPC) }
            try underlying.markRestored(sessionID: sessionID)
        }
    }

    func testJournalWriteFailureStillRestoresDurableActiveSessionButCannotClaimOff() throws {
        let (_, journal, backend) = try fixture()
        let storage = FaultingJournal(journal)
        let host = try RecoveryRuntime(backend: backend, journalStore: storage, bootID: "test")
        _ = host.process(.start(.permanent), now: 100, power: .init(source: .ac, percent: 100, sampledAt: 100))
        XCTAssertEqual(try journal.load()?.phase, .active)
        storage.refuseWrites = true
        let stopped = host.process(.stop, now: 101, power: .init(source: .ac, percent: 100, sampledAt: 101))
        XCTAssertEqual(backend.snapshot, SleepSnapshot(actualDisabled: false, persistedDisabled: false))
        XCTAssertEqual(backend.restoreCount, 1)
        XCTAssertEqual(stopped.snapshot.state, .failed)
        XCTAssertFalse(stopped.snapshot.verifiedOff)
        XCTAssertEqual(try journal.load()?.phase, .active)
        storage.refuseWrites = false
        host.tick(now: 131, power: .init(source: .ac, percent: 100, sampledAt: 131))
        XCTAssertTrue(host.response(now: 131).snapshot.verifiedOff)
        XCTAssertEqual(try journal.load()?.phase, .restored)
    }

    func testJournalWriteFailureAfterMutationRestoresDurablePreparedSession() throws {
        let (_, journal, backend) = try fixture()
        let storage = FaultingJournal(journal)
        let host = try RecoveryRuntime(backend: backend, journalStore: storage, bootID: "test")
        backend.beforeApply = { storage.refuseWrites = true }
        let result = host.process(.start(.permanent), now: 100, power: .init(source: .ac, percent: 100, sampledAt: 100))
        XCTAssertEqual(backend.applyCount, 1)
        XCTAssertEqual(backend.restoreCount, 1)
        XCTAssertEqual(backend.snapshot, SleepSnapshot(actualDisabled: false, persistedDisabled: false))
        XCTAssertEqual(result.snapshot.state, .failed)
        XCTAssertFalse(result.snapshot.verifiedOff)
        XCTAssertEqual(try journal.load()?.phase, .prepared)
    }

    func testRestorationWriteFailureRequiresMatchingReadableDurableRecord() throws {
        for invalidProof in ["missing", "corrupt", "differentSession", "differentBoot", "differentGeneration", "differentBaseline", "restored"] {
            let (_, journal, backend) = try fixture()
            let storage = FaultingJournal(journal)
            let host = try RecoveryRuntime(backend: backend, journalStore: storage, bootID: "test")
            _ = host.process(.start(.permanent), now: 100, power: .init(source: .ac, percent: 100, sampledAt: 100))
            let active = try XCTUnwrap(journal.load())
            storage.refuseWrites = true
            storage.readOverride = {
                switch invalidProof {
                case "missing": return nil
                case "corrupt": throw PlatformError.invalidJournal
                case "differentSession": return RecoveryRecord(sessionID: UUID(), generation: active.generation, bootID: active.bootID, phase: .active, original: active.original)
                case "differentBoot": return RecoveryRecord(sessionID: active.sessionID, generation: active.generation, bootID: "other", phase: .active, original: active.original)
                case "differentGeneration": return RecoveryRecord(sessionID: active.sessionID, generation: active.generation + 1, bootID: active.bootID, phase: .active, original: active.original)
                case "differentBaseline": return RecoveryRecord(sessionID: active.sessionID, generation: active.generation, bootID: active.bootID, phase: .active, original: .init(actualDisabled: true, persistedDisabled: true))
                default:
                    var completed = active; completed.phase = .restored; return completed
                }
            }
            let stopped = host.process(.stop, now: 101, power: .init(source: .ac, percent: 100, sampledAt: 101))
            XCTAssertEqual(backend.restoreCount, 0, invalidProof)
            XCTAssertEqual(stopped.snapshot.state, .failed, invalidProof)
            XCTAssertFalse(stopped.snapshot.verifiedOff, invalidProof)
        }
    }

    func testFailedInitialJournalWriteDoesNotMutateWithoutDurableProof() throws {
        let (_, journal, backend) = try fixture()
        let storage = FaultingJournal(journal)
        let host = try RecoveryRuntime(backend: backend, journalStore: storage, bootID: "test")
        storage.refuseWrites = true
        let result = host.process(.start(.permanent), now: 100, power: .init(source: .ac, percent: 100, sampledAt: 100))
        XCTAssertEqual(backend.applyCount, 0)
        XCTAssertEqual(backend.restoreCount, 0)
        XCTAssertFalse(result.snapshot.verifiedOff)
        XCTAssertNil(try journal.load())
    }

    func testRestoreRetryPreservesOriginalSafetyStopReason() throws {
        for reason: SessionIssue in [.leaseExpired, .lowBattery] {
            let (_, journal, backend) = try fixture()
            let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "test")
            _ = host.process(.start(.permanent), now: 100, power: .init(source: .ac, percent: 100, sampledAt: 100))
            backend.refuseRestore = true
            let retryTime: UInt64
            switch reason {
            case .leaseExpired:
                for now: UInt64 in [105, 110, 115, 120, 125, 130] {
                    _ = host.process(.health, now: now, power: .init(source: .ac, percent: 100, sampledAt: now))
                }
                retryTime = 160
            default:
                _ = host.process(.status, now: 101, power: .init(source: .battery, percent: 20, sampledAt: 101))
                retryTime = 131
            }
            XCTAssertEqual(host.response(now: retryTime - 30).snapshot.state, .failed)
            XCTAssertEqual(host.response(now: retryTime - 30).lastStopReason, reason)
            backend.refuseRestore = false
            host.tick(now: retryTime, power: .init(source: .ac, percent: 100, sampledAt: retryTime))
            XCTAssertTrue(host.response(now: retryTime).snapshot.verifiedOff)
            XCTAssertEqual(host.response(now: retryTime).lastStopReason, reason)
            XCTAssertEqual(try journal.load()?.stopReason, reason.rawValue)
            let restarted = try RecoveryRuntime(backend: backend, journal: journal, bootID: "next", now: retryTime + 1)
            XCTAssertEqual(restarted.response(now: retryTime + 1).lastStopReason, reason)
        }
    }

    func testFiveMinuteTimerExpiresDespiteContinuingValidHeartbeats() throws {
        let (_, journal, backend) = try fixture()
        let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "test")
        let active = host.process(.start(.fiveMinutes), now: 100, power: .init(source: .ac, percent: 100, sampledAt: 100))
        let identity = try XCTUnwrap(active.snapshot.session?.identity)
        for second in stride(from: 105, through: 395, by: 5) {
            let now = UInt64(second)
            let refreshed = host.process(.heartbeat(identity), now: now, power: .init(source: .ac, percent: 100, sampledAt: now))
            XCTAssertEqual(refreshed.snapshot.state, .active)
        }
        let expired = host.process(.heartbeat(identity), now: 400, power: .init(source: .ac, percent: 100, sampledAt: 400))
        XCTAssertTrue(expired.snapshot.verifiedOff)
        XCTAssertEqual(expired.lastStopReason, .timerExpired)
        XCTAssertEqual(backend.applyCount, 1)
        XCTAssertEqual(backend.restoreCount, 1)
        XCTAssertEqual(backend.snapshot, SleepSnapshot(actualDisabled: false, persistedDisabled: false))
        XCTAssertEqual(try journal.load()?.phase, .restored)
        XCTAssertEqual(try journal.load()?.stopReason, SessionIssue.timerExpired.rawValue)
    }

    func testDelayedStartExpiresThirtySecondsAfterUIConfirmation() throws {
        let (_, journal, backend) = try fixture()
        let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "test")
        let active = host.process(.start(.fiveMinutes), now: 109, power: .init(source: .ac, percent: 100, sampledAt: 109), confirmationAt: 100)
        XCTAssertEqual(active.snapshot.state, .active)
        XCTAssertEqual(active.snapshot.session?.deadline, 409)
        XCTAssertEqual(active.snapshot.session?.leaseDeadline, 130)
        for now: UInt64 in [114, 119, 124, 129, 130] {
            _ = host.process(.health, now: now, power: .init(source: .ac, percent: 100, sampledAt: now))
        }
        XCTAssertTrue(host.response(now: 130).snapshot.verifiedOff)
        XCTAssertEqual(host.response(now: 130).lastStopReason, .leaseExpired)
        XCTAssertEqual(backend.restoreCount, 1)
    }

    func testDelayedHeartbeatUsesOriginalConfirmationAndCannotReviveExpiredLease() throws {
        let (_, journal, backend) = try fixture()
        let host = try RecoveryRuntime(backend: backend, journal: journal, bootID: "test")
        let active = host.process(.start(.fiveMinutes), now: 100, power: .init(source: .ac, percent: 100, sampledAt: 100), confirmationAt: 100)
        let identity = try XCTUnwrap(active.snapshot.session?.identity)
        let refreshed = host.process(.heartbeat(identity), now: 114, power: .init(source: .ac, percent: 100, sampledAt: 114), confirmationAt: 105)
        XCTAssertEqual(refreshed.snapshot.session?.deadline, 400)
        XCTAssertEqual(refreshed.snapshot.session?.leaseDeadline, 135)
        for now: UInt64 in [119, 124, 129, 134] {
            _ = host.process(.health, now: now, power: .init(source: .ac, percent: 100, sampledAt: now))
        }
        let expired = host.process(.heartbeat(identity), now: 135, power: .init(source: .ac, percent: 100, sampledAt: 135), confirmationAt: 130)
        XCTAssertTrue(expired.snapshot.verifiedOff)
        XCTAssertEqual(expired.lastStopReason, .leaseExpired)
        XCTAssertEqual(backend.applyCount, 1)
        XCTAssertEqual(backend.restoreCount, 1)
    }

}

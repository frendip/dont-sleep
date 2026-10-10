import XCTest
@testable import DontSleepCore

final class SessionEngineTests: XCTestCase {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    func testBatteryBoundaryBlocks20AndAllows21() {
        for (percent, permitted) in [(19, false), (20, false), (21, true)] {
            var engine = SessionEngine()
            _ = engine.handle(.power(.init(source: .battery, percent: percent, sampledAt: 0)), now: 0)
            let effects = engine.handle(.enable(mode: .permanent, sessionID: id), now: 0)
            XCTAssertEqual(effects.isEmpty, !permitted, "percent \(percent)")
            XCTAssertEqual(engine.snapshot.state, permitted ? .enabling : .off)
        }
    }

    // Each test protects an observable transition, timing bound or stale-callback rejection.
    func start(_ mode: Mode = .permanent, at now: UInt64 = 0) -> SessionEngine {
        var engine = SessionEngine()
        _ = engine.handle(.power(.init(source: .ac, percent: 20, sampledAt: now)), now: now)
        _ = engine.handle(.enable(mode: mode, sessionID: id), now: now)
        guard let session = engine.snapshot.session else { XCTFail("No enabling session"); return engine }
        _ = engine.handle(.applyResult(session.identity, verified: true), now: now)
        return engine
    }

    func testAllModeDurationsAndVerifiedApply() {
        let cases: [(Mode, UInt64?)] = [(.permanent, nil), (.fiveMinutes, 300), (.fifteenMinutes, 900),
            (.thirtyMinutes, 1800), (.oneHour, 3600), (.fourHours, 14400), (.eightHours, 28800)]
        for (mode, deadline) in cases {
            let engine = start(mode)
            XCTAssertEqual(engine.snapshot.state, .active)
            XCTAssertEqual(engine.snapshot.session?.deadline, deadline)
        }
    }

    func testACAllows20ButUnknownAndStalePowerBlock() {
        let cases: [(PowerSnapshot, UInt64, Bool)] = [
            (.init(source: .ac, percent: 20, sampledAt: 0), 0, true),
            (.init(source: .ac, percent: nil, sampledAt: 0), 0, true),
            (.init(source: .unknown, percent: 80, sampledAt: 0), 0, false),
            (.init(source: .battery, percent: nil, sampledAt: 0), 0, false),
            (.init(source: .battery, percent: 101, sampledAt: 0), 0, false),
            (.init(source: .battery, percent: 90, sampledAt: 1), 0, false),
            (.init(source: .ac, percent: 80, sampledAt: 0), 6, false)]
        for (power, now, permitted) in cases {
            var engine = SessionEngine()
            _ = engine.handle(.power(power), now: now)
            XCTAssertEqual(engine.handle(.enable(mode: .permanent, sessionID: id), now: now).isEmpty, !permitted)
        }
    }

    func testBatterySwitchStopsImmediatelyAndACDoesNotResume() {
        var engine = start(.fiveMinutes)
        let effects = engine.handle(.power(.init(source: .battery, percent: 20, sampledAt: 1)), now: 1)
        XCTAssertEqual(engine.snapshot.state, .restoring)
        XCTAssertEqual(engine.snapshot.issue, .lowBattery)
        XCTAssertEqual(effects.count, 2)
        XCTAssertTrue(effects.contains(.cancelSchedule))
        let identity = engine.snapshot.session!.identity
        _ = engine.handle(.restoreResult(identity, verified: true), now: 1)
        XCTAssertEqual(engine.snapshot.state, .off)
        XCTAssertTrue(engine.handle(.power(.init(source: .ac, percent: 20, sampledAt: 2)), now: 2).isEmpty)
        XCTAssertEqual(engine.snapshot.state, .off)
        XCTAssertTrue(engine.snapshot.canEnable(at: 2))
    }

    func testValidPowerSwitchPreservesDeadlineAndIdentity() {
        var engine = start(.fiveMinutes)
        let before = engine.snapshot.session
        XCTAssertTrue(engine.handle(.power(.init(source: .battery, percent: 21, sampledAt: 1)), now: 1).isEmpty)
        XCTAssertEqual(engine.snapshot.session, before)
    }

    func testRepeatedTimerSelectionResetsFullDurationAndPermanentClearsDeadline() {
        var engine = start(.fiveMinutes)
        let original = engine.snapshot.session!.identity
        _ = engine.handle(.power(.init(source: .ac, percent: 20, sampledAt: 10)), now: 10)
        let effects = engine.handle(.enable(mode: .fiveMinutes, sessionID: UUID()), now: 10)
        XCTAssertEqual(engine.snapshot.state, .active)
        XCTAssertEqual(engine.snapshot.session?.deadline, 310)
        XCTAssertEqual(engine.snapshot.session?.identity.sessionID, id)
        XCTAssertNotEqual(engine.snapshot.session?.identity, original)
        XCTAssertEqual(effects, [.schedule(engine.snapshot.session!)])
        _ = engine.handle(.enable(mode: .permanent, sessionID: UUID()), now: 10)
        XCTAssertNil(engine.snapshot.session?.deadline)
    }

    func testToggleRememberedModeStartsFullDurationAfterVerifiedOff() {
        var engine = start(.fiveMinutes)
        _ = engine.handle(.disable, now: 1)
        _ = engine.handle(.restoreResult(engine.snapshot.session!.identity, verified: true), now: 1)
        XCTAssertEqual(engine.snapshot.selectedMode, .fiveMinutes)
        _ = engine.handle(.power(.init(source: .ac, percent: 50, sampledAt: 10)), now: 10)
        _ = engine.handle(.enable(mode: engine.snapshot.selectedMode, sessionID: UUID()), now: 10)
        XCTAssertEqual(engine.snapshot.session?.deadline, 310)
        XCTAssertEqual(SessionEngine().snapshot.selectedMode, .permanent)
    }

    func testLeaseExpiresAtExactly30AndLateHeartbeatCannotRescue() {
        var engine = start()
        let identity = engine.snapshot.session!.identity
        _ = engine.handle(.power(.init(source: .ac, percent: 80, sampledAt: 29)), now: 29)
        XCTAssertEqual(engine.snapshot.state, .active)
        let effects = engine.handle(.heartbeat(identity), now: 30)
        XCTAssertEqual(engine.snapshot.state, .restoring)
        XCTAssertEqual(engine.snapshot.issue, .leaseExpired)
        XCTAssertTrue(effects.contains(.cancelSchedule))
    }

    func testOnlyCurrentHeartbeatRenewsLease() {
        var engine = start()
        let identity = engine.snapshot.session!.identity
        let wrong = SessionIdentity(sessionID: identity.sessionID, generation: identity.generation + 1)
        _ = engine.handle(.power(.init(source: .ac, percent: 50, sampledAt: 5)), now: 5)
        XCTAssertTrue(engine.handle(.heartbeat(wrong), now: 5).isEmpty)
        XCTAssertEqual(engine.snapshot.session?.leaseDeadline, 30)
        _ = engine.handle(.heartbeat(identity), now: 5)
        XCTAssertEqual(engine.snapshot.session?.leaseDeadline, 35)
    }

    func testClockRollbackDoesNotExtendSession() {
        var engine = start(.fiveMinutes, at: 100)
        let identity = engine.snapshot.session!.identity
        _ = engine.handle(.heartbeat(identity), now: 95)
        XCTAssertEqual(engine.snapshot.session?.deadline, 400)
        XCTAssertEqual(engine.snapshot.session?.leaseDeadline, 130)
        _ = engine.handle(.power(.init(source: .ac, percent: 50, sampledAt: 129)), now: 129)
        _ = engine.handle(.tick, now: 130)
        XCTAssertEqual(engine.snapshot.state, .restoring)
    }

    func testDeadlineStopsWithoutWaitingForLease() {
        var engine = start(.fiveMinutes)
        for second in stride(from: 5, through: 295, by: 5) {
            let now = UInt64(second)
            _ = engine.handle(.power(.init(source: .ac, percent: 50, sampledAt: now)), now: now)
            _ = engine.handle(.heartbeat(engine.snapshot.session!.identity), now: now)
        }
        _ = engine.handle(.power(.init(source: .ac, percent: 50, sampledAt: 300)), now: 300)
        XCTAssertEqual(engine.snapshot.state, .restoring)
        XCTAssertEqual(engine.snapshot.issue, .timerExpired)
    }

    func testDuplicateQuitAndFailedRestoreCannotTerminate() {
        var engine = start()
        let effects = engine.handle(.quit, now: 1)
        XCTAssertEqual(effects.count, 2)
        XCTAssertTrue(engine.handle(.quit, now: 1).isEmpty)
        let first = engine.snapshot.session!.identity
        XCTAssertTrue(engine.handle(.restoreResult(first, verified: false), now: 1).isEmpty)
        XCTAssertEqual(engine.snapshot.state, .failed)
        XCTAssertFalse(engine.snapshot.verifiedOff)
        XCTAssertTrue(engine.handle(.quit, now: 1).isEmpty)
        let retry = engine.handle(.retryRestore, now: 2)
        XCTAssertEqual(retry.count, 1)
        let second = engine.snapshot.session!.identity
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(engine.handle(.restoreResult(first, verified: true), now: 2).isEmpty)
        XCTAssertEqual(engine.snapshot.state, .restoring)
        XCTAssertEqual(engine.handle(.restoreResult(second, verified: true), now: 2), [.terminate])
        XCTAssertTrue(engine.snapshot.verifiedOff)
        XCTAssertTrue(engine.handle(.quit, now: 2).isEmpty)
    }

    func testStaleApplyCannotResurrectStoppedSession() {
        var engine = SessionEngine()
        _ = engine.handle(.power(.init(source: .ac, percent: 50, sampledAt: 0)), now: 0)
        _ = engine.handle(.enable(mode: .permanent, sessionID: id), now: 0)
        let original = engine.snapshot.session!.identity
        _ = engine.handle(.disable, now: 0)
        XCTAssertTrue(engine.handle(.applyResult(original, verified: true), now: 0).isEmpty)
        XCTAssertEqual(engine.snapshot.state, .restoring)
        XCTAssertNotEqual(engine.snapshot.session?.identity, original)
    }

    func testUnverifiedApplyRestoresAndCannotReportActive() {
        var engine = SessionEngine()
        _ = engine.handle(.power(.init(source: .ac, percent: 50, sampledAt: 0)), now: 0)
        _ = engine.handle(.enable(mode: .permanent, sessionID: id), now: 0)
        _ = engine.handle(.applyResult(engine.snapshot.session!.identity, verified: false), now: 0)
        XCTAssertEqual(engine.snapshot.state, .restoring)
        XCTAssertEqual(engine.snapshot.issue, .applyFailed)
    }

    func testUnknownAndExpiredPowerStopActiveSession() {
        var unknown = start()
        _ = unknown.handle(.power(.init(source: .unknown, percent: 90, sampledAt: 1)), now: 1)
        XCTAssertEqual(unknown.snapshot.state, .restoring)
        XCTAssertEqual(unknown.snapshot.issue, .powerUnavailable)
        var stale = start()
        _ = stale.handle(.tick, now: 6)
        XCTAssertEqual(stale.snapshot.state, .restoring)
        XCTAssertEqual(stale.snapshot.issue, .powerUnavailable)
    }

    func testServiceLossRestoresAndBlocksUntilReadyWithoutResume() {
        var engine = start()
        _ = engine.handle(.servicesReady(false), now: 1)
        XCTAssertEqual(engine.snapshot.state, .restoring)
        _ = engine.handle(.restoreResult(engine.snapshot.session!.identity, verified: true), now: 1)
        XCTAssertEqual(engine.snapshot.state, .setupRequired)
        XCTAssertTrue(engine.snapshot.verifiedOff)
        XCTAssertTrue(engine.handle(.enable(mode: .permanent, sessionID: UUID()), now: 1).isEmpty)
        _ = engine.handle(.servicesReady(true), now: 1)
        XCTAssertEqual(engine.snapshot.state, .off)
    }

    func testBootRecoveryBlocksActivationAndNeverResumesOldDeadline() {
        var engine = SessionEngine()
        let old = SessionIdentity(sessionID: id, generation: 99)
        let effects = engine.handle(.bootRecovery(old), now: 0)
        XCTAssertEqual(engine.snapshot.state, .restoring)
        XCTAssertEqual(effects.count, 2)
        XCTAssertNil(engine.snapshot.session?.deadline)
        XCTAssertTrue(engine.handle(.enable(mode: .fiveMinutes, sessionID: UUID()), now: 0).isEmpty)
        guard let recovery = engine.snapshot.session else { return XCTFail("Missing recovery session") }
        _ = engine.handle(.restoreResult(recovery.identity, verified: true), now: 0)
        XCTAssertEqual(engine.snapshot.state, .off)
        XCTAssertNil(engine.snapshot.session)
    }

    func testOffQuitTerminatesOnce() {
        var engine = SessionEngine()
        XCTAssertEqual(engine.handle(.quit, now: 0), [.terminate])
        XCTAssertTrue(engine.handle(.quit, now: 0).isEmpty)
    }


    func testRejectedEnableExplainsStalePowerWithoutStartingOperation() {
        var engine = SessionEngine()
        _ = engine.handle(.power(.init(source: .ac, percent: 50, sampledAt: 0)), now: 0)
        XCTAssertTrue(engine.handle(.enable(mode: .permanent, sessionID: id), now: 6).isEmpty)
        XCTAssertEqual(engine.snapshot.issue, .powerUnavailable)
        XCTAssertEqual(engine.snapshot.state, .off)
    }


    func testUninspectedStartupCannotVerifyOffOrTerminateUntilReadinessProof() {
        var engine = SessionEngine(servicesReady: false)
        XCTAssertFalse(engine.snapshot.verifiedOff)
        XCTAssertFalse(SessionSnapshot(state: .setupRequired).verifiedOff)
        XCTAssertTrue(engine.handle(.quit, now: 0).isEmpty)
        XCTAssertTrue(engine.handle(.quit, now: 0).isEmpty)
        XCTAssertTrue(engine.handle(.power(.init(source: .ac, percent: 80, sampledAt: 0)), now: 0).isEmpty)
        XCTAssertFalse(engine.snapshot.verifiedOff)
        XCTAssertTrue(engine.handle(.servicesReady(true), now: 0).isEmpty)
        XCTAssertFalse(engine.snapshot.verifiedOff)
        XCTAssertEqual(engine.handle(.recoveryChecked, now: 0), [.terminate])
        XCTAssertTrue(engine.snapshot.verifiedOff)
        XCTAssertTrue(engine.handle(.recoveryChecked, now: 0).isEmpty)
    }

    func testStartupQuitWaitsThroughRecoveryFailureUntilVerifiedRestore() {
        var engine = SessionEngine(servicesReady: false)
        XCTAssertTrue(engine.handle(.quit, now: 0).isEmpty)
        _ = engine.handle(.bootRecovery(.init(sessionID: id, generation: 7)), now: 0)
        XCTAssertFalse(engine.snapshot.verifiedOff)
        _ = engine.handle(.restoreResult(engine.snapshot.session!.identity, verified: false), now: 1)
        XCTAssertFalse(engine.snapshot.verifiedOff)
        _ = engine.handle(.retryRestore, now: 2)
        XCTAssertEqual(engine.handle(.restoreResult(engine.snapshot.session!.identity, verified: true), now: 2), [.terminate])
        XCTAssertEqual(engine.snapshot.state, .setupRequired)
        XCTAssertTrue(engine.snapshot.verifiedOff)
    }


    func testFuturePowerCannotBecomeTrustedByAdvancingTime() {
        var engine = SessionEngine()
        _ = engine.handle(.power(.init(source: .ac, percent: 80, sampledAt: 2)), now: 0)
        XCTAssertTrue(engine.handle(.enable(mode: .permanent, sessionID: id), now: 0).isEmpty)
        XCTAssertTrue(engine.handle(.enable(mode: .permanent, sessionID: id), now: 2).isEmpty)
        XCTAssertEqual(engine.snapshot.state, .off)
        XCTAssertFalse(engine.snapshot.canEnable(at: 3))
        _ = engine.handle(.power(.init(source: .ac, percent: 80, sampledAt: 3)), now: 3)
        XCTAssertFalse(engine.handle(.enable(mode: .permanent, sessionID: id), now: 3).isEmpty)
        XCTAssertEqual(engine.snapshot.state, .enabling)
    }

    func testCleanJournalProofAllowsOfflineQuitButCannotOverrideActiveRecovery() {
        var engine = SessionEngine(servicesReady: false)
        XCTAssertTrue(engine.handle(.quit, now: 0).isEmpty)
        XCTAssertEqual(engine.handle(.recoveryChecked, now: 0), [.terminate])
        XCTAssertEqual(engine.snapshot.state, .setupRequired)
        XCTAssertTrue(engine.snapshot.verifiedOff)
        var recovering = SessionEngine(servicesReady: false)
        _ = recovering.handle(.bootRecovery(.init(sessionID: id, generation: 7)), now: 0)
        XCTAssertTrue(recovering.handle(.recoveryChecked, now: 0).isEmpty)
        XCTAssertFalse(recovering.snapshot.verifiedOff)
        XCTAssertEqual(recovering.snapshot.state, .restoring)
    }


    func testServiceReadinessCannotReplaceJournalInspectionForActivation() {
        var engine = SessionEngine(servicesReady: false)
        _ = engine.handle(.power(.init(source: .ac, percent: 80, sampledAt: 0)), now: 0)
        _ = engine.handle(.servicesReady(true), now: 0)
        XCTAssertFalse(engine.snapshot.verifiedOff)
        XCTAssertFalse(engine.snapshot.canEnable(at: 0))
        XCTAssertTrue(engine.handle(.enable(mode: .permanent, sessionID: id), now: 0).isEmpty)
        _ = engine.handle(.recoveryChecked, now: 0)
        XCTAssertTrue(engine.snapshot.verifiedOff)
        XCTAssertFalse(engine.handle(.enable(mode: .permanent, sessionID: id), now: 0).isEmpty)
    }


    func failedActivation() -> SessionEngine {
        var engine = SessionEngine()
        _ = engine.handle(.power(.init(source: .ac, percent: 80, sampledAt: 0)), now: 0)
        _ = engine.handle(.enable(mode: .permanent, sessionID: id), now: 0)
        _ = engine.handle(.applyResult(engine.snapshot.session!.identity, verified: false), now: 0)
        return engine
    }

    func testApplyFailureRemainsVisibleAfterRestoreAndRoutineStatusRefreshes() {
        var engine = failedActivation()
        _ = engine.handle(.restoreResult(engine.snapshot.session!.identity, verified: true), now: 0)
        XCTAssertTrue(engine.snapshot.verifiedOff)
        XCTAssertEqual(engine.snapshot.issue, .applyFailed)
        _ = engine.handle(.power(.init(source: .ac, percent: 80, sampledAt: 1)), now: 1)
        _ = engine.handle(.servicesReady(true), now: 1)
        _ = engine.handle(.tick, now: 1)
        XCTAssertEqual(engine.snapshot.issue, .applyFailed)
        _ = engine.handle(.enable(mode: .fiveMinutes, sessionID: UUID()), now: 1)
        XCTAssertEqual(engine.snapshot.state, .enabling)
        XCTAssertNil(engine.snapshot.issue)
    }

    func testUnsafePowerTemporarilyTakesPrecedenceOverStickyActivationFailure() {
        var engine = failedActivation()
        _ = engine.handle(.restoreResult(engine.snapshot.session!.identity, verified: true), now: 0)
        _ = engine.handle(.power(.init(source: .battery, percent: 20, sampledAt: 1)), now: 1)
        XCTAssertEqual(engine.snapshot.issue, .lowBattery)
        XCTAssertTrue(engine.handle(.enable(mode: .permanent, sessionID: id), now: 1).isEmpty)
        _ = engine.handle(.power(.init(source: .unknown, percent: nil, sampledAt: 2)), now: 2)
        XCTAssertEqual(engine.snapshot.issue, .powerUnavailable)
        _ = engine.handle(.power(.init(source: .ac, percent: 80, sampledAt: 3)), now: 3)
        XCTAssertEqual(engine.snapshot.issue, .applyFailed)
        XCTAssertTrue(engine.snapshot.verifiedOff)
    }

    func testVerifiedRestoreRetryDoesNotForgetOriginalActivationFailure() {
        var engine = failedActivation()
        _ = engine.handle(.restoreResult(engine.snapshot.session!.identity, verified: false), now: 0)
        XCTAssertEqual(engine.snapshot.issue, .restoreFailed)
        _ = engine.handle(.retryRestore, now: 1)
        _ = engine.handle(.restoreResult(engine.snapshot.session!.identity, verified: true), now: 1)
        XCTAssertTrue(engine.snapshot.verifiedOff)
        XCTAssertEqual(engine.snapshot.issue, .applyFailed)
    }

}

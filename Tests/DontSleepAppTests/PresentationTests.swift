import XCTest
import DontSleepCore
@testable import DontSleepApp

final class PresentationTests: XCTestCase {
    func testLowBatteryBlocksControlsWithoutLosingVerifiedOff() {
        let p = MenuPresentation(snapshot: SessionSnapshot(state: .off, power: .init(source: .battery, percent: 20, sampledAt: 100), issue: .lowBattery), serviceTime: 100)
        XCTAssertFalse(p.allowsModes)
        XCTAssertEqual(p.badge, .warning)
        XCTAssertFalse(p.bolt)
        XCTAssertEqual(p.quitTitle, "Выйти")
        XCTAssertEqual(p.charge, "Заряд 20%")
    }
    func testActiveTimerUsesServiceClockAndHoursWithoutClipping() {
        let identity = SessionIdentity(sessionID: UUID(), generation: 2)
        let session = Session(identity: identity, mode: .eightHours, deadline: 28_900, leaseDeadline: 130)
        let p = MenuPresentation(snapshot: SessionSnapshot(state: .active, selectedMode: .eightHours, session: session, power: .init(source: .ac, percent: 100, sampledAt: 100)), serviceTime: 100)
        XCTAssertEqual(p.remaining, "Осталось 8:00:00")
        XCTAssertEqual(p.charge, "Заряд 100%")
        XCTAssertTrue(p.allowsModes)
        XCTAssertTrue(p.switchOn)
        XCTAssertTrue(p.bolt)
        XCTAssertEqual(p.quitTitle, "Выключить и выйти")
    }
    func testNoTimerWhileOffOrPermanentAndStalePowerIsUnknown() {
        let p = MenuPresentation(snapshot: SessionSnapshot(state: .off, power: .init(source: .battery, percent: 78, sampledAt: 90)), serviceTime: 100)
        XCTAssertNil(p.remaining)
        XCTAssertEqual(p.charge, "Заряд —")
        XCTAssertFalse(p.allowsModes)
        let active = MenuPresentation(snapshot: SessionSnapshot(state: .active), serviceTime: 100)
        XCTAssertNil(active.remaining)
    }
    func testRestorationFailureHasErrorInsteadOfMisleadingOffSwitch() {
        let identity = SessionIdentity(sessionID: UUID(), generation: 2)
        let p = MenuPresentation(snapshot: SessionSnapshot(state: .failed, session: Session(identity: identity, mode: .permanent, deadline: nil, leaseDeadline: 130), issue: .restoreFailed), serviceTime: 100)
        XCTAssertFalse(p.showsSwitch)
        XCTAssertFalse(p.allowsModes)
        XCTAssertEqual(p.title, "Сон не восстановлен")
        XCTAssertEqual(p.badge, .error)
        // Failed restoration does not itself prove the actuator is still active.
        XCTAssertFalse(p.bolt)
    }
    func testTransportFailureNeverRepresentsLastSnapshotAsCurrentOffOrOn() {
        let p = MenuPresentation(snapshot: SessionSnapshot(state: .active), serviceTime: 100, connected: false)
        XCTAssertEqual(p.title, "Не удалось проверить состояние")
        XCTAssertEqual(p.charge, "Заряд —")
        XCTAssertFalse(p.showsSwitch)
        XCTAssertFalse(p.bolt)
        XCTAssertEqual(p.badge, .error)
        XCTAssertFalse(p.allowsModes)
    }
    func testQuitWaitsForVerifiedRestoreAndCoalescesDuplicateRequests() {
        var gate = QuitGate()
        XCTAssertFalse(gate.canTerminate(after: SessionSnapshot(state: .off)))
        XCTAssertTrue(gate.request())
        XCTAssertFalse(gate.request())
        XCTAssertFalse(gate.canTerminate(after: SessionSnapshot(state: .restoring)))
        XCTAssertFalse(gate.canTerminate(after: SessionSnapshot(state: .failed, issue: .restoreFailed)))
        XCTAssertFalse(gate.canTerminate(after: nil))
        XCTAssertTrue(gate.canTerminate(after: SessionSnapshot(state: .off)))
    }
}

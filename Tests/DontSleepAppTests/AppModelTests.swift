import XCTest
import DontSleepCore
import DontSleepIPC
@testable import DontSleepApp

final class AppModelTests: XCTestCase {
    @MainActor func testQuitDoesNotTerminateOnFailedRestoreButCompletesAfterVerifiedOff() async {
        let service = FixtureService(response: .init(snapshot: .init(state: .failed, issue: .restoreFailed), serviceTime: 100))
        var terminations = 0
        let model = AppModel(client: service) { terminations += 1 }
        await model.requestQuit()
        XCTAssertEqual(terminations, 0)
        XCTAssertEqual(model.snapshot?.state, .failed)
        await model.requestQuit()
        XCTAssertEqual(service.stops, 1, "Repeated quit must not enqueue parallel or duplicate restoration")
        service.response = .init(snapshot: .init(state: .off), serviceTime: 101)
        await model.refresh()
        XCTAssertEqual(terminations, 1)
        await model.refresh()
        XCTAssertEqual(terminations, 1, "Termination acknowledgement is emitted once")
    }
    @MainActor func testMissingServiceRequiresSetupWithoutInventingVerifiedOffOrStarting() async {
        let service = FixtureService(response: .init(snapshot: .init(state: .off), serviceTime: 100))
        service.error = ServiceTransportError.unavailable
        let model = AppModel(client: service, noInstallationExists: { true }) {}
        await model.refresh()
        XCTAssertTrue(model.setupRequired)
        XCTAssertFalse(model.connected)
        XCTAssertNil(model.snapshot)
        await model.select(.fiveMinutes)
        XCTAssertEqual(service.starts, 0)
    }
    @MainActor func testNeverInstalledCanQuitOnlyWithPositiveAbsenceEvidence() async {
        let service = FixtureService(response: .init(snapshot: .init(state: .off), serviceTime: 100))
        service.error = ServiceTransportError.unavailable
        var exits = 0
        let model = AppModel(client: service, noInstallationExists: { true }) { exits += 1 }
        await model.refresh()
        XCTAssertEqual(model.presentation.quitTitle, "Выйти")
        await model.requestQuit()
        XCTAssertEqual(exits, 1)
        XCTAssertEqual(service.stops, 0)
        var uncertainExits = 0
        let installed = AppModel(client: service, noInstallationExists: { false }) { uncertainExits += 1 }
        await installed.refresh()
        XCTAssertFalse(installed.setupRequired)
        XCTAssertEqual(installed.presentation.title, "Не удалось проверить состояние")
        await installed.requestQuit()
        XCTAssertEqual(uncertainExits, 0)
    }
    @MainActor func testNewUILaunchToggleDoesNotReuseDaemonPreviousTimer() async {
        let service = FixtureService(response: .init(snapshot: .init(state: .off, selectedMode: .eightHours, power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100))
        let model = AppModel(client: service) {}
        await model.refresh()
        await model.toggle(true)
        XCTAssertEqual(service.startedModes, [.permanent])
    }
    @MainActor func testFreshUIRestoresPreviousActiveSessionWithoutResumingIt() async {
        let identity = SessionIdentity(sessionID: UUID(), generation: 1)
        let service = FixtureService(response: .init(snapshot: .init(state: .active, session: .init(identity: identity, mode: .permanent, deadline: nil, leaseDeadline: 130), power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100))
        let model = AppModel(client: service) {}
        await model.refresh()
        XCTAssertEqual(service.stops, 1)
        XCTAssertFalse(model.presentation.allowsModes)
        XCTAssertEqual(model.presentation.title, "Восстановление сна…")
    }
    @MainActor func testExplicitStopQueuesBehindInFlightStatus() async {
        let service = FixtureService(response: .init(snapshot: .init(state: .off, power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100))
        let model = AppModel(client: service) {}
        await model.refresh()
        let identity = SessionIdentity(sessionID: UUID(), generation: 1)
        service.response = .init(snapshot: .init(state: .active, session: .init(identity: identity, mode: .permanent, deadline: nil, leaseDeadline: 130), power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100)
        await model.select(.permanent)
        service.blockStatus = true
        let refresh = Task { await model.refresh() }
        while service.waiter == nil { await Task.yield() }
        XCTAssertFalse(model.presentation.allowsModes, "Modes must visibly wait for the serialized status request")
        XCTAssertTrue(model.presentation.switchOn)
        XCTAssertFalse(model.presentation.operationPending, "An active OFF switch and quit remain available")
        await model.toggle(false)
        service.waiter?.resume(); service.waiter = nil
        await refresh.value
        XCTAssertEqual(service.stops, 1)
    }
    @MainActor func testLostStopReplyNeverRenewsOrReenablesPreviousSession() async {
        let service = FixtureService(response: .init(snapshot: .init(state: .off, power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100))
        let model = AppModel(client: service) {}
        await model.refresh()
        let identity = SessionIdentity(sessionID: UUID(), generation: 1)
        service.response = .init(snapshot: .init(state: .active, session: .init(identity: identity, mode: .permanent, deadline: nil, leaseDeadline: 130), power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100)
        await model.select(.permanent)
        service.error = ServiceTransportError.timedOut
        await model.toggle(false)
        service.error = nil
        await model.refresh()
        XCTAssertFalse(model.presentation.allowsModes)
        XCTAssertEqual(model.presentation.title, "Восстановление сна…")
    }
    @MainActor func testPendingQuitCompletesWhenAbsentInstallationIsPositivelyReverified() async {
        let service = FixtureService(response: .init(snapshot: .init(state: .off), serviceTime: 100))
        service.error = ServiceTransportError.unavailable
        var absent = false
        var exits = 0
        let model = AppModel(client: service, noInstallationExists: { absent }) { exits += 1 }
        await model.refresh()
        await model.requestQuit()
        XCTAssertEqual(exits, 0)
        absent = true
        await model.refresh()
        XCTAssertEqual(exits, 1)
    }
    @MainActor func testActivityEndsBeforeStopRequestAndDoesNotDuplicateAcrossStatusRefresh() async {
        var events: [String] = []
        let activity = ActivityLease(begin: { _ in events.append("begin"); return NSObject() }, end: { _ in events.append("end") })
        let service = FixtureService(response: .init(snapshot: .init(state: .off, power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100))
        service.onStop = { events.append("stop") }
        let model = AppModel(client: service, activity: activity) {}
        await model.refresh()
        let identity = SessionIdentity(sessionID: UUID(), generation: 1)
        service.response = .init(snapshot: .init(state: .active, session: .init(identity: identity, mode: .permanent, deadline: nil, leaseDeadline: 130), power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100)
        await model.select(.permanent)
        await model.refresh()
        await model.toggle(false)
        XCTAssertEqual(events, ["begin", "end", "stop"])
    }
    @MainActor func testFrequentStatusRefreshesCannotPostponeOwnedSessionHeartbeat() async throws {
        let service = FixtureService(response: .init(snapshot: .init(state: .off, power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100))
        let model = AppModel(client: service, activity: ActivityLease(begin: { _ in NSObject() }, end: { _ in })) {}
        await model.refresh()
        let identity = SessionIdentity(sessionID: UUID(), generation: 1)
        service.response = .init(snapshot: .init(state: .active, session: .init(identity: identity, mode: .permanent, deadline: nil, leaseDeadline: 130), power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100)
        await model.select(.permanent)
        for _ in 0..<30 { await model.refresh(); try await Task.sleep(for: .milliseconds(200)) }
        let heartbeats = service.heartbeats
        service.response = .init(snapshot: .init(state: .off), serviceTime: 101)
        await model.toggle(false)
        XCTAssertGreaterThanOrEqual(heartbeats, 1)
    }
    @MainActor func testOlderResponseCannotOverwriteNewerVerifiedState() async {
        let service = FixtureService(response: .init(snapshot: .init(state: .off), serviceTime: 200))
        let model = AppModel(client: service) {}
        await model.refresh()
        service.response = .init(snapshot: .init(state: .failed, issue: .restoreFailed), serviceTime: 199)
        await model.refresh()
        XCTAssertEqual(model.snapshot?.state, .off)
    }
}

private final class FixtureService: ServiceClient {
    var response: ServiceResponse
    var error: Error?
    var stops = 0
    var heartbeats = 0
    var starts = 0
    var onStop: () -> Void = {}
    var startedModes: [Mode] = []
    var blockStatus = false
    var waiter: CheckedContinuation<Void, Never>?
    init(response: ServiceResponse) { self.response = response }
    func status() async throws -> ServiceResponse { if blockStatus { blockStatus = false; await withCheckedContinuation { waiter = $0 } }; if let error { throw error }; return response }
    func start(mode: Mode) async throws -> ServiceResponse { starts += 1; startedModes.append(mode); if let error { throw error }; return response }
    func heartbeat(identity: SessionIdentity) async throws -> ServiceResponse { heartbeats += 1; if let error { throw error }; return response }
    func stop() async throws -> ServiceResponse { stops += 1; onStop(); if let error { throw error }; return response }
}

import XCTest
import AppKit
import DontSleepCore
import DontSleepIPC
import DontSleepPlatform
@testable import DontSleepApp

final class AppModelTests: XCTestCase {
    @MainActor func testReopenProvidesControlsAndCloseOnlyHidesWindow() async throws {
        _ = NSApplication.shared
        let service = FixtureService(response: .init(snapshot: .init(state: .off), serviceTime: 100))
        var exits = 0
        let model = AppModel(client: service) { exits += 1 }
        AppDelegate.model = model
        let delegate: NSApplicationDelegate = AppDelegate()
        defer { AppDelegate.model = nil }
        XCTAssertEqual(delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false), false)
        let window = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "DontSleepControls" && $0.isVisible })
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.styleMask.contains(.resizable))
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(exits, 0)
        XCTAssertEqual(service.stops, 0, "Closing controls must not stop the session")
        XCTAssertEqual(delegate.applicationShouldTerminateAfterLastWindowClosed?(NSApp), false)
        XCTAssertEqual(delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false), false)
        XCTAssertTrue(window.isVisible, "Reopen must reuse the hidden controls window")
        window.performClose(nil)
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.dontsleep.showControls"), object: String(getpid()), userInfo: nil, deliverImmediately: true)
        for _ in 0..<50 { if window.isVisible { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(window.isVisible, "A second copy must explicitly ask the existing instance to show controls")
        window.performClose(nil)
    }
    @MainActor func testCommandQInControlsWaitsForVerifiedRestoration() async throws {
        _ = NSApplication.shared
        let service = FixtureService(response: .init(snapshot: .init(state: .failed, issue: .restoreFailed), serviceTime: 100))
        var exits = 0
        let model = AppModel(client: service) { exits += 1 }
        AppDelegate.model = model
        let delegate: NSApplicationDelegate = AppDelegate()
        defer { AppDelegate.model = nil }
        _ = delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        let window = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "DontSleepControls" && $0.isVisible })
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        XCTAssertTrue(window.performKeyEquivalent(with: event), "The controls window must handle Command-Q")
        for _ in 0..<50 { if service.stops > 0 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(service.stops, 1)
        XCTAssertEqual(exits, 0, "Failed restoration must keep the app running")
        XCTAssertTrue(window.isVisible)
        service.response = .init(snapshot: .init(state: .off), serviceTime: 101)
        await model.refresh()
        XCTAssertEqual(exits, 1, "Only verified OFF completes the pending quit")
        window.performClose(nil)
    }

    @MainActor func testHidingControlsPreservesOtherSurfacePollingAndOwnedHeartbeat() async throws {
        _ = NSApplication.shared
        let service = FixtureService(response: .init(snapshot: .init(state: .off, power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100))
        let model = AppModel(client: service, activity: ActivityLease(begin: { _ in NSObject() }, end: { _ in })) {}
        await model.refresh()
        let identity = SessionIdentity(sessionID: UUID(), generation: 1)
        service.response = .init(snapshot: .init(state: .active, session: .init(identity: identity, mode: .permanent, deadline: nil, leaseDeadline: 130), power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100)
        await model.toggle(true)
        let controls = ControlsWindowController(model: model)
        controls.showControls()
        model.setMenuVisible(true)
        controls.window?.performClose(nil)
        XCTAssertEqual(service.stops, 0)
        let statuses = service.statuses
        try await Task.sleep(for: .seconds(6))
        XCTAssertGreaterThan(service.statuses, statuses, "The still-open menu must continue refreshing")
        XCTAssertGreaterThan(service.heartbeats, 0)
        model.setMenuVisible(false)
        let heartbeats = service.heartbeats
        try await Task.sleep(for: .seconds(6))
        XCTAssertGreaterThan(service.heartbeats, heartbeats, "Hiding every control surface must not stop lease renewal")
        XCTAssertEqual(service.stops, 0)
        service.response = .init(snapshot: .init(state: .off), serviceTime: 101)
        await model.toggle(false)
    }
    @MainActor func testControlsResizeToKeepExitReachableWhenErrorAppears() async throws {
        _ = NSApplication.shared
        let service = FixtureService(response: .init(snapshot: .init(state: .off), serviceTime: 100))
        let model = AppModel(client: service) {}
        await model.refresh()
        let controls = ControlsWindowController(model: model)
        controls.showControls()
        defer { controls.window?.performClose(nil) }
        model.setupError = "Не удалось завершить настройку служебного компонента. Проверьте разрешение администратора и повторите попытку. Приложение должно оставаться доступным для безопасного выхода."
        try await Task.sleep(for: .milliseconds(200))
        let content = try XCTUnwrap(controls.window?.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(content.bounds.height, 300)
        XCTAssertGreaterThanOrEqual(content.bounds.height + 1, content.fittingSize.height, "The added error must not clip the exit button below the window")
    }
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
    @MainActor func testSelectingModeDoesNotStartAndRunningSessionCannotBeChanged() async {
        let power = PowerSnapshot(source: .ac, percent: 78, sampledAt: 100)
        let service = FixtureService(response: .init(snapshot: .init(state: .off, power: power), serviceTime: 100))
        let model = AppModel(client: service, activity: ActivityLease(begin: { _ in NSObject() }, end: { _ in })) {}
        await model.refresh()
        await model.select(.fifteenMinutes)
        XCTAssertEqual(model.presentation.selectedMode, .fifteenMinutes)
        XCTAssertEqual(service.starts, 0, "Selection alone must not enable sleep prevention")
        XCTAssertFalse(model.presentation.switchOn)
        let identity = SessionIdentity(sessionID: UUID(), generation: 1)
        service.response = .init(snapshot: .init(state: .active, selectedMode: .fifteenMinutes, session: .init(identity: identity, mode: .fifteenMinutes, deadline: 1000, leaseDeadline: 130), power: power), serviceTime: 100)
        await model.toggle(true)
        XCTAssertEqual(service.startedModes, [.fifteenMinutes])
        XCTAssertFalse(model.presentation.allowsModes)
        await model.select(.oneHour)
        await model.select(.fifteenMinutes)
        await model.toggle(true)
        XCTAssertEqual(service.startedModes, [.fifteenMinutes], "Active mode and countdown cannot be replaced or reset")
        service.response = .init(snapshot: .init(state: .off, power: power), serviceTime: 100)
        await model.toggle(false)
        XCTAssertEqual(model.presentation.selectedMode, .fifteenMinutes)
        XCTAssertNil(model.presentation.remaining)
        XCTAssertTrue(model.presentation.allowsModes)
        await model.toggle(true)
        XCTAssertEqual(service.startedModes, [.fifteenMinutes, .fifteenMinutes], "Switching off preserves the selected duration for the next full start")
        await model.select(.oneHour)
        XCTAssertEqual(service.starts, 2)
        await model.toggle(true)
        XCTAssertEqual(service.startedModes, [.fifteenMinutes, .fifteenMinutes, .oneHour])
    }
    @MainActor func testNewUILaunchToggleDoesNotReuseDaemonPreviousTimer() async {
        let service = FixtureService(response: .init(snapshot: .init(state: .off, selectedMode: .eightHours, power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100))
        let model = AppModel(client: service) {}
        await model.refresh()
        XCTAssertEqual(model.presentation.selectedMode, .permanent)
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
    @MainActor func testBackgroundRefreshKeepsOffControlsStableAndAcceptsSelection() async {
        let service = FixtureService(response: .init(snapshot: .init(state: .off, power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100))
        let model = AppModel(client: service) {}
        await model.refresh()
        service.blockStatus = true
        let refresh = Task { await model.refresh() }
        while service.waiter == nil { await Task.yield() }
        XCTAssertTrue(model.presentation.allowsModes, "A background read must not flash enabled controls into their disabled appearance")
        XCTAssertFalse(model.presentation.operationPending)
        XCTAssertEqual(model.presentation.title, "Выключено")
        await model.select(.fifteenMinutes)
        XCTAssertEqual(model.presentation.selectedMode, .fifteenMinutes)
        XCTAssertEqual(service.starts, 0)
        service.waiter?.resume(); service.waiter = nil
        await refresh.value
        XCTAssertTrue(model.presentation.allowsModes)
    }
    @MainActor func testStartDuringRefreshWaitsAndRechecksSafetyBeforeSending() async {
        for result in ["safe", "lowBattery", "disconnected", "quit", "oldReply"] {
            let power = PowerSnapshot(source: .ac, percent: 78, sampledAt: 100)
            let service = FixtureService(response: .init(snapshot: .init(state: .off, power: power), serviceTime: 100))
            let model = AppModel(client: service, noInstallationExists: { false }) {}
            await model.refresh()
            await model.select(.fifteenMinutes)
            service.blockStatus = true
            let refresh = Task { await model.refresh() }
            while service.waiter == nil { await Task.yield() }
            await model.toggle(true)
            XCTAssertTrue(model.presentation.operationPending, result)
            XCTAssertEqual(service.starts, 0, "Never overlap a start with an unfinished request")
            await model.select(.oneHour)
            await model.toggle(true)
            switch result {
            case "lowBattery": service.response = .init(snapshot: .init(state: .off, power: .init(source: .battery, percent: 20, sampledAt: 101)), serviceTime: 101)
            case "disconnected": service.error = ServiceTransportError.unavailable
            case "quit": await model.requestQuit()
            case "oldReply": service.response = .init(snapshot: .init(state: .off, power: power), serviceTime: 99)
            default: break
            }
            service.waiter?.resume(); service.waiter = nil
            await refresh.value
            XCTAssertEqual(service.startedModes, result == "safe" ? [.fifteenMinutes] : [], result)
            if result == "quit" { XCTAssertEqual(service.stops, 1) }
        }
    }
    @MainActor func testQueuedStartIsCancelledWhenRefreshDiscoversSessionNeedingRecovery() async {
        let power = PowerSnapshot(source: .ac, percent: 78, sampledAt: 100)
        let service = FixtureService(response: .init(snapshot: .init(state: .off, power: power), serviceTime: 100))
        let model = AppModel(client: service) {}
        await model.refresh()
        service.blockStatus = true
        let refresh = Task { await model.refresh() }
        while service.waiter == nil { await Task.yield() }
        await model.toggle(true)
        let identity = SessionIdentity(sessionID: UUID(), generation: 1)
        service.response = .init(snapshot: .init(state: .active, session: .init(identity: identity, mode: .permanent, deadline: nil, leaseDeadline: 130), power: power), serviceTime: 100)
        service.onStop = { service.response = .init(snapshot: .init(state: .off, power: power), serviceTime: 101) }
        service.waiter?.resume(); service.waiter = nil
        await refresh.value
        XCTAssertEqual(service.stops, 1)
        XCTAssertEqual(service.starts, 0, "Recovery must cancel, not postpone, a queued start")
        await model.refresh()
        XCTAssertEqual(service.starts, 0)
    }
    @MainActor func testVisiblePollingRefreshesBeforePowerDisplayExpires() async throws {
        // Sampling and response timestamps can straddle an integer-second boundary.
        let service = FixtureService(response: .init(snapshot: .init(state: .off, power: .init(source: .ac, percent: 78, sampledAt: 99)), serviceTime: 100))
        let model = AppModel(client: service) {}
        await model.refresh()
        model.setMenuVisible(true)
        defer { model.setMenuVisible(false) }
        while service.statuses < 2 { await Task.yield() }
        service.blockStatus = true
        for _ in 0..<70 {
            if service.waiter != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(service.waiter)
        XCTAssertEqual(model.presentation.charge, "Заряд 78%", "Normal polling must begin before the displayed sample expires")
        XCTAssertTrue(model.presentation.allowsModes)
        service.response = .init(snapshot: .init(state: .off, power: .init(source: .ac, percent: 78, sampledAt: 106)), serviceTime: 106)
        service.waiter?.resume(); service.waiter = nil
        await Task.yield()
    }
    @MainActor func testExplicitStopQueuesBehindInFlightStatus() async {
        let service = FixtureService(response: .init(snapshot: .init(state: .off, power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100))
        let model = AppModel(client: service) {}
        await model.refresh()
        let identity = SessionIdentity(sessionID: UUID(), generation: 1)
        service.response = .init(snapshot: .init(state: .active, session: .init(identity: identity, mode: .permanent, deadline: nil, leaseDeadline: 130), power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100)
        await model.toggle(true)
        service.blockStatus = true
        let refresh = Task { await model.refresh() }
        while service.waiter == nil { await Task.yield() }
        XCTAssertFalse(model.presentation.allowsModes, "Modes remain locked while a session is active")
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
        await model.toggle(true)
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
        await model.toggle(true)
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
        await model.toggle(true)
        for _ in 0..<30 { await model.refresh(); try await Task.sleep(for: .milliseconds(200)) }
        let heartbeats = service.heartbeats
        service.response = .init(snapshot: .init(state: .off), serviceTime: 101)
        await model.toggle(false)
        XCTAssertGreaterThanOrEqual(heartbeats, 1)
    }
    @MainActor func testDelayedClientDispatchKeepsOriginalUIConfirmationTime() async throws {
        let power = PowerSnapshot(source: .ac, percent: 78, sampledAt: 100)
        let service = FixtureService(response: .init(snapshot: .init(state: .off, power: power), serviceTime: 100))
        let model = AppModel(client: service, activity: ActivityLease(begin: { _ in NSObject() }, end: { _ in })) {}
        await model.refresh()
        let identity = SessionIdentity(sessionID: UUID(), generation: 1)
        service.response = .init(snapshot: .init(state: .active, session: .init(identity: identity, mode: .permanent, deadline: nil, leaseDeadline: 130), power: power), serviceTime: 100)
        service.blockStart = true
        let start = Task { await model.toggle(true) }
        while service.startWaiter == nil { await Task.yield() }
        let startWasDispatchedBy = PlatformClock.now()
        try await Task.sleep(for: .milliseconds(1100))
        service.startWaiter?.resume(); service.startWaiter = nil
        await start.value
        let startIssuedAt = try XCTUnwrap(service.receivedStartIssuedAt)
        XCTAssertLessThanOrEqual(startIssuedAt, startWasDispatchedBy)
        XCTAssertLessThan(startIssuedAt, PlatformClock.now())

        service.blockHeartbeat = true
        for _ in 0..<70 {
            if service.heartbeatWaiter != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(service.heartbeatWaiter)
        let heartbeatWasDispatchedBy = PlatformClock.now()
        try await Task.sleep(for: .milliseconds(1100))
        service.heartbeatWaiter?.resume(); service.heartbeatWaiter = nil
        for _ in 0..<100 { if service.receivedHeartbeatIssuedAt != nil { break }; await Task.yield() }
        let heartbeatIssuedAt = try XCTUnwrap(service.receivedHeartbeatIssuedAt)
        XCTAssertLessThanOrEqual(heartbeatIssuedAt, heartbeatWasDispatchedBy)
        XCTAssertLessThan(heartbeatIssuedAt, PlatformClock.now())
        // Even if transport builds its envelope later, the original UI confirmation has expired.
        let delayed = ServiceRequest(command: .heartbeat(identity), nonce: UUID(), sequence: 1, issuedAt: heartbeatIssuedAt)
        XCTAssertThrowsError(try delayed.validateForExecution(at: heartbeatWasDispatchedBy + 10))
        service.response = .init(snapshot: .init(state: .off), serviceTime: 101)
        await model.requestQuit()
    }
    @MainActor func testQuitQueuedBehindStartWaitsForVerifiedStopAfterLateReplyOrTimeout() async {
        for timesOut in [false, true] {
            let power = PowerSnapshot(source: .ac, percent: 78, sampledAt: 100)
            let service = FixtureService(response: .init(snapshot: .init(state: .off, power: power), serviceTime: 100))
            var exits = 0
            var activityBegins = 0
            let model = AppModel(client: service, activity: ActivityLease(begin: { _ in activityBegins += 1; return NSObject() }, end: { _ in })) { exits += 1 }
            await model.refresh()
            service.blockStart = true; service.blockStop = true
            let start = Task { await model.toggle(true) }
            while service.startWaiter == nil { await Task.yield() }
            await model.requestQuit()
            await model.requestQuit()
            XCTAssertEqual(service.stops, 0)
            XCTAssertEqual(exits, 0)
            let identity = SessionIdentity(sessionID: UUID(), generation: 1)
            service.response = .init(snapshot: .init(state: .active, session: .init(identity: identity, mode: .permanent, deadline: nil, leaseDeadline: 130), power: power), serviceTime: 101)
            if timesOut { service.error = ServiceTransportError.timedOut }
            service.onStop = { service.error = nil }
            service.startWaiter?.resume(); service.startWaiter = nil
            while service.stopWaiter == nil { await Task.yield() }
            XCTAssertEqual(service.stops, 1)
            XCTAssertEqual(exits, 0, "Even a completed start cannot bypass the awaited stop")
            XCTAssertEqual(activityBegins, 0, "Quit intent must never briefly reacquire activity or renew the late start")
            service.response = .init(snapshot: .init(state: .off, recoveryVerified: false), serviceTime: 102)
            service.stopWaiter?.resume(); service.stopWaiter = nil
            await start.value
            XCTAssertEqual(exits, 0, "An OFF label without recovery proof is insufficient")
            service.response = .init(snapshot: .init(state: .off), serviceTime: 103)
            await model.refresh()
            XCTAssertEqual(exits, 1)
            XCTAssertEqual(service.heartbeats, 0)
        }
    }
    @MainActor func testLostOwnedResponseKeepsHiddenRecoveryPollingAndNeverResumesLease() async throws {
        for failsDuringStart in [false, true] {
            let power = PowerSnapshot(source: .ac, percent: 78, sampledAt: 100)
            let service = FixtureService(response: .init(snapshot: .init(state: .off, power: power), serviceTime: 100))
            var activityBegins = 0
            let model = AppModel(client: service, activity: ActivityLease(begin: { _ in activityBegins += 1; return NSObject() }, end: { _ in })) {}
            await model.refresh()
            let identity = SessionIdentity(sessionID: UUID(), generation: 1)
            service.response = .init(snapshot: .init(state: .active, session: .init(identity: identity, mode: .permanent, deadline: nil, leaseDeadline: 130), power: power), serviceTime: 100)
            if failsDuringStart { service.error = ServiceTransportError.timedOut }
            await model.toggle(true)
            if !failsDuringStart {
                service.error = ServiceTransportError.unavailable
                await model.refresh()
            }
            XCTAssertFalse(model.connected)
            let statuses = service.statuses
            let beginsBeforeRecovery = activityBegins
            service.error = nil
            service.onStop = { service.response = .init(snapshot: .init(state: .off, power: power), serviceTime: 101) }
            // No visible surface and no external refresh: unknown ownership still needs observation.
            for _ in 0..<65 {
                if service.stops > 0 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertGreaterThan(service.statuses, statuses)
            XCTAssertEqual(service.stops, 1)
            XCTAssertEqual(service.heartbeats, 0, "A recovered response must never resume an uncertain lease")
            XCTAssertEqual(activityBegins, beginsBeforeRecovery)
            XCTAssertTrue(model.snapshot?.verifiedOff == true)
            // Ensure old code's active polling task is also stopped after a failing assertion.
            service.response = .init(snapshot: .init(state: .off, power: power), serviceTime: 102)
            await model.requestQuit()
        }
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
    var statuses = 0
    var stops = 0
    var heartbeats = 0
    var starts = 0
    var onStop: () -> Void = {}
    var startedModes: [Mode] = []
    var receivedStartIssuedAt: UInt64?
    var receivedHeartbeatIssuedAt: UInt64?
    var blockHeartbeat = false
    var heartbeatWaiter: CheckedContinuation<Void, Never>?
    var blockStart = false
    var blockStop = false
    var startWaiter: CheckedContinuation<Void, Never>?
    var stopWaiter: CheckedContinuation<Void, Never>?
    var blockStatus = false
    var waiter: CheckedContinuation<Void, Never>?
    init(response: ServiceResponse) { self.response = response }
    func status() async throws -> ServiceResponse { statuses += 1; if blockStatus { blockStatus = false; await withCheckedContinuation { waiter = $0 } }; if let error { throw error }; return response }
    func start(mode: Mode, issuedAt: UInt64) async throws -> ServiceResponse { starts += 1; startedModes.append(mode); if blockStart { blockStart = false; await withCheckedContinuation { startWaiter = $0 } }; receivedStartIssuedAt = issuedAt; if let error { throw error }; return response }
    func heartbeat(identity: SessionIdentity, issuedAt: UInt64) async throws -> ServiceResponse { heartbeats += 1; if blockHeartbeat { blockHeartbeat = false; await withCheckedContinuation { heartbeatWaiter = $0 } }; receivedHeartbeatIssuedAt = issuedAt; if let error { throw error }; return response }
    func stop() async throws -> ServiceResponse { stops += 1; onStop(); if blockStop { blockStop = false; await withCheckedContinuation { stopWaiter = $0 } }; if let error { throw error }; return response }
}

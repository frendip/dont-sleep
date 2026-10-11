import XCTest
import AppKit
import DontSleepCore
import DontSleepIPC
@testable import DontSleepApp

final class NativeStatusMenuTests: XCTestCase {
    @MainActor func testCheckmarkedRowsKeepIdentityAndSelectingDoesNotStart() async throws {
        _ = NSApplication.shared
        let service = NativeMenuFixtureService()
        let model = AppModel(client: service) {}
        await model.refresh()
        let controller = NativeStatusMenuController(model: model)
        let items = controller.menu.items
        let buttons = controller.modeButtons
        XCTAssertFalse(controller.menu.autoenablesItems)
        XCTAssertEqual(controller.modeButtons.count, 7)
        XCTAssertTrue(controller.modeButtons.allSatisfy { $0.isEnabled && $0.cell?.accessibilityRole() == .radioButton })
        XCTAssertEqual(controller.modeButtons.filter { $0.state == .on }.map(\.title), ["Без таймера"])
        let fifteen = try XCTUnwrap(controller.modeButtons.first { $0.title == "На 15 минут" })
        fifteen.performClick(nil)
        for _ in 0..<30 { if model.preferredMode == .fifteenMinutes { break }; await Task.yield() }
        controller.refresh()
        XCTAssertEqual(controller.modeButtons.filter { $0.state == .on }.map(\.title), ["На 15 минут"])
        XCTAssertEqual(service.starts, 0)
        await model.refresh()
        await Task.yield()
        XCTAssertTrue(zip(items, controller.menu.items).allSatisfy { $0 === $1 }, "Background refresh must update native rows in place")
        XCTAssertTrue(zip(buttons, controller.modeButtons).allSatisfy { $0 === $1 })
        XCTAssertEqual(controller.modeGroup.accessibilityRole(), .radioGroup)
        XCTAssertTrue(controller.modeButtons.allSatisfy { $0.cell?.accessibilityRole() == .radioButton })
        XCTAssertEqual(controller.quitItem.title, "Выйти")
        XCTAssertEqual(controller.quitItem.keyEquivalent, "q")
        XCTAssertEqual(controller.quitItem.keyEquivalentModifierMask, .command)
    }

    @MainActor func testModeRowHitAreaIncludesTrailingWhitespace() throws {
        _ = NSApplication.shared
        let row = MenuModeRowButton(frame: NSRect(x: 0, y: 0, width: 312, height: 28))
        row.title = "На 5 минут"
        let window = NSWindow(contentRect: row.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = row
        let edge = row.convert(NSPoint(x: row.bounds.maxX - 3, y: row.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: edge,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let cell = try XCTUnwrap(row.cell)
        XCTAssertTrue(cell.hitTest(for: event, in: row.bounds, of: row).contains(.trackableArea))
        row.isEnabled = false
        XCTAssertFalse(cell.hitTest(for: event, in: row.bounds, of: row).contains(.trackableArea))
    }

    @MainActor func testNativeOpenWindowCommandProvidesKeyboardPathWithoutStartingMode() async throws {
        _ = NSApplication.shared
        let service = NativeMenuFixtureService()
        let model = AppModel(client: service) {}
        await model.refresh()
        var opens = 0
        let controller = NativeStatusMenuController(model: model) { opens += 1 }
        let item = controller.openWindowItem
        XCTAssertNil(item.view, "Open Window must remain a keyboard-navigable native menu item")
        XCTAssertEqual(item.keyEquivalent, "o")
        XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(service.starts, 0)
    }

    @MainActor func testActiveTimerDisablesRowsAndUpdatesHeaderWithoutReplacingItems() async throws {
        _ = NSApplication.shared
        let service = NativeMenuFixtureService()
        let model = AppModel(client: service, activity: ActivityLease(begin: { _ in NSObject() }, end: { _ in })) {}
        await model.refresh()
        await model.select(.fifteenMinutes)
        let identity = SessionIdentity(sessionID: UUID(), generation: 1)
        service.response = .init(snapshot: .init(state: .active,
            session: .init(identity: identity, mode: .fifteenMinutes, deadline: 1_000, leaseDeadline: 130),
            power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100)
        await model.toggle(true)
        let controller = NativeStatusMenuController(model: model)
        XCTAssertTrue(controller.modeButtons.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(controller.headerView.toggleControl.state, .on)
        XCTAssertTrue(controller.headerView.toggleControl.isEnabled)
        XCTAssertEqual(controller.headerView.remainingLabel.stringValue, "Осталось 15:00")
        XCTAssertEqual(controller.quitItem.title, "Выключить и выйти")
        let icon = controller.statusItem.button?.image
        let item = controller.modeButtons[2]
        service.response = .init(snapshot: service.response.snapshot, serviceTime: 101)
        await model.refresh()
        controller.refresh()
        XCTAssertEqual(controller.headerView.remainingLabel.stringValue, "Осталось 14:59")
        XCTAssertTrue(controller.modeButtons[2] === item)
        XCTAssertTrue(controller.statusItem.button?.image === icon)
        service.response = .init(snapshot: .init(state: .off), serviceTime: 102)
        await model.toggle(false)
    }

    @MainActor func testNativeQuitWaitsForConfirmedRestoration() async throws {
        _ = NSApplication.shared
        let service = NativeMenuFixtureService()
        service.response = .init(snapshot: .init(state: .failed, issue: .restoreFailed), serviceTime: 100)
        var exits = 0
        let exited = expectation(description: "quit completes after verified OFF")
        let model = AppModel(client: service) { exits += 1; exited.fulfill() }
        await model.refresh()
        let controller = NativeStatusMenuController(model: model)
        let quit = controller.quitItem
        let baselineStops = service.stops
        let stopSent = expectation(description: "menu quit sends stop")
        service.onStop = { stopSent.fulfill() }
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(quit.action), to: quit.target, from: quit))
        await fulfillment(of: [stopSent], timeout: 2)
        XCTAssertEqual(service.stops, baselineStops + 1)
        XCTAssertEqual(exits, 0)
        service.response = .init(snapshot: .init(state: .off), serviceTime: 101)
        // A refresh during the pending stop queues its work; returning from
        // refresh is not an acknowledgement that termination has completed.
        await model.refresh()
        await fulfillment(of: [exited], timeout: 2)
        XCTAssertEqual(exits, 1)
    }

    @MainActor func testHeaderUsesContentHeightAndNativeSwitchAction() {
        _ = NSApplication.shared
        let header = NativeMenuHeaderView()
        let off = MenuPresentation(snapshot: .init(state: .off,
            power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100)
        header.update(off, setupError: nil)
        let offHeight = header.frame.height
        XCTAssertNil(header.layer, "Header must leave the native menu material visible")
        XCTAssertTrue(header.toggleControl.isEnabled)
        var enabled: Bool?
        header.onToggle = { enabled = $0 }
        header.toggleControl.state = .on
        XCTAssertTrue(NSApp.sendAction(header.toggleControl.action!, to: header.toggleControl.target, from: header.toggleControl))
        XCTAssertEqual(enabled, true)
        let failed = MenuPresentation(snapshot: .init(state: .failed, issue: .restoreFailed), serviceTime: 100)
        header.update(failed, setupError: "Проверьте разрешения служебного компонента и повторите попытку настройки.")
        XCTAssertGreaterThan(header.frame.height, offHeight)
        XCTAssertTrue(header.toggleControl.isHidden)
        header.update(off, setupError: nil)
        XCTAssertEqual(header.frame.height, offHeight, "Resolved warnings must not leave empty space")
        let low = MenuPresentation(snapshot: .init(state: .off,
            power: .init(source: .battery, percent: 20, sampledAt: 100)), serviceTime: 100)
        header.update(low, setupError: nil)
        XCTAssertFalse(header.toggleControl.isEnabled)
    }
}

private final class NativeMenuFixtureService: ServiceClient {
    var response = ServiceResponse(snapshot: .init(state: .off,
        power: .init(source: .ac, percent: 78, sampledAt: 100)), serviceTime: 100)
    var starts = 0
    var stops = 0
    var onStop: () -> Void = {}
    func status() async throws -> ServiceResponse { response }
    func start(mode: Mode, issuedAt: UInt64) async throws -> ServiceResponse { starts += 1; return response }
    func heartbeat(identity: SessionIdentity, issuedAt: UInt64) async throws -> ServiceResponse { response }
    func stop() async throws -> ServiceResponse { stops += 1; onStop(); return response }
}

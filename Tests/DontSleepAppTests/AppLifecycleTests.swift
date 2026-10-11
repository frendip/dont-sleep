import XCTest
import AppKit
import DontSleepCore
import DontSleepIPC
@testable import DontSleepApp

final class AppLifecycleTests: XCTestCase {
    @MainActor func testApplicationMenuQuitKeepsRestorationGateWithoutSettingsCommand() async throws {
        _ = NSApplication.shared
        let service = LaunchFixtureService()
        var exits = 0
        let model = AppModel(client: service) { exits += 1 }
        await model.refresh()
        AppDelegate.model = model
        let delegate = AppDelegate()
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu; AppDelegate.model = nil }
        delegate.configureApplicationMenu()
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let commands = try XCTUnwrap(menu.items.first?.submenu)
        XCTAssertFalse(commands.items.contains { $0.keyEquivalent == "," })
        let quit = try XCTUnwrap(commands.items.first { $0.keyEquivalent == "q" })
        XCTAssertEqual(quit.keyEquivalentModifierMask, .command)
        let baseline = service.stops
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        XCTAssertTrue(menu.performKeyEquivalent(with: event))
        for _ in 0..<50 { if service.stops > baseline { break }; await Task.yield() }
        XCTAssertEqual(service.stops, baseline + 1)
        XCTAssertEqual(exits, 0)
        service.response = .init(snapshot: .init(state: .off), serviceTime: 101)
        await model.refresh()
        XCTAssertEqual(exits, 1)
    }
}

private final class LaunchFixtureService: ServiceClient {
    var response = ServiceResponse(snapshot: .init(state: .failed, issue: .restoreFailed), serviceTime: 100)
    var stops = 0
    func status() async throws -> ServiceResponse { response }
    func start(mode: Mode, issuedAt: UInt64) async throws -> ServiceResponse { response }
    func heartbeat(identity: SessionIdentity, issuedAt: UInt64) async throws -> ServiceResponse { response }
    func stop() async throws -> ServiceResponse { stops += 1; return response }
}

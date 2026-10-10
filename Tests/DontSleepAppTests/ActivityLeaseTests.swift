import XCTest
import DontSleepCore
import DontSleepIPC
@testable import DontSleepApp

final class ActivityLeaseTests: XCTestCase {
    func testActivityAllowsSystemAndDisplaySleepAndHasOneBoundedLifetime() {
        var options: [ProcessInfo.ActivityOptions] = []
        var ended = 0
        let lease = ActivityLease(begin: { options.append($0); return NSObject() }, end: { _ in ended += 1 })
        lease.setActive(true); lease.setActive(true)
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options.first, .userInitiatedAllowingIdleSystemSleep)
        XCTAssertFalse(options.first?.contains(.idleSystemSleepDisabled) ?? true)
        XCTAssertFalse(options.first?.contains(.idleDisplaySleepDisabled) ?? true)
        XCTAssertFalse(options.first?.contains(.latencyCritical) ?? true)
        lease.setActive(false); lease.setActive(false)
        XCTAssertEqual(ended, 1)
    }
}

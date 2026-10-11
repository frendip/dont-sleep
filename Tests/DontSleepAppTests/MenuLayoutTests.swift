import XCTest
import AppKit
import SwiftUI
@testable import DontSleepApp

final class MenuLayoutTests: XCTestCase {
    @MainActor func testMenuUsesContentHeightInsteadOfExtraHeightOfferedByHost() {
        _ = NSApplication.shared
        for (name, presentation) in NativePreviews.fixtures {
            let host = NSHostingController(rootView: MenuPanel(presentation: presentation))
            let compact = host.sizeThatFits(in: NSSize(width: 340, height: 1))
            let expanded = host.sizeThatFits(in: NSSize(width: 340, height: 900))
            XCTAssertEqual(expanded.height, compact.height, accuracy: 1, "\(name): panel must use its content height for any proposed height")
            XCTAssertEqual(expanded.width, 340, accuracy: 1)
        }
    }
}

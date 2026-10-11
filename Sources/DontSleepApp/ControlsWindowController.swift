import AppKit
import SwiftUI

/// The same controls remain reachable even when macOS hides the status item.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        MenuPanel(presentation: model.presentation, setupError: model.setupError,
                  onToggle: { enabled in Task { await model.toggle(enabled) } },
                  onSelect: { mode in Task { await model.select(mode) } },
                  onQuit: { Task { await model.requestQuit() } },
                  onSetup: { Task { await model.installService() } })
    }
}

@MainActor final class ControlsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let host = NSHostingController(rootView: MenuContent(model: model))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.identifier = NSUserInterfaceItemIdentifier("DontSleepControls")
        window.title = "Don’t Sleep"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(host.view.fittingSize)
        window.center()
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }

    func showControls() {
        model.setMenuVisible(true, source: .window)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        // This only hides controls; the existing session and its lease remain owned.
        model.setMenuVisible(false, source: .window)
    }
}

import SwiftUI
import AppKit
import DontSleepIPC

@main
struct DontSleepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model: AppModel
    private static var lifetimeLock: InstanceLock?

    init() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render-previews"), args.indices.contains(index + 1) {
            do { try NativePreviews.render(to: URL(fileURLWithPath: args[index + 1], isDirectory: true)); exit(0) }
            catch { fputs("Preview rendering failed: \(error)\n", stderr); exit(1) }
        }
        if let index = args.firstIndex(of: "--export-icon"), args.indices.contains(index + 1) {
            do { try NativePreviews.exportIcon(to: URL(fileURLWithPath: args[index + 1], isDirectory: true)); exit(0) }
            catch { fputs("Icon export failed: \(error)\n", stderr); exit(1) }
        }
        if args.contains("--verify-installation-payload") {
            do {
                _ = try ServiceInstaller.prepareCommand()
                print("Installation payload verified: pinned script bytes and live app code identity. No authorization prompt, service connection, installation, or power change was made.")
                exit(0)
            } catch { fputs("Installation payload verification failed: \(error)\n", stderr); exit(1) }
        }
        if args.contains("--smoke-test") {
            print("Don’t Sleep: native SwiftUI menu entry point loaded. No service connection or power change was made.")
            exit(0)
        }
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.dontsleep.app", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let lock = try InstanceLock.acquire(at: directory.appendingPathComponent("instance.lock")) else {
                if let pid = InstanceGate.existingPID(current: getpid(), bundleID: Bundle.main.bundleIdentifier, processes: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.bundleIdentifier) }) { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) }
                exit(0)
            }
            Self.lifetimeLock = lock
        } catch { fputs("Cannot acquire Don’t Sleep instance lock: \(error)\n", stderr); exit(1) }
        let model = AppModel(client: XPCServiceClient()) {
            AppDelegate.allowTermination = true
            NSApplication.shared.terminate(nil)
        }
        AppDelegate.model = model
        _model = StateObject(wrappedValue: model)
    }
    var body: some Scene {
        MenuBarExtra {
            MenuPanel(presentation: model.presentation, setupError: model.setupError,
                      onToggle: { enabled in Task { await model.toggle(enabled) } },
                      onSelect: { mode in Task { await model.select(mode) } },
                      onQuit: { Task { await model.requestQuit() } },
                      onSetup: { Task { await model.installService() } })
                .onAppear { model.setMenuVisible(true) }
                .onDisappear { model.setMenuVisible(false) }
        } label: {
            EyeMark(bolt: model.presentation.bolt, badge: model.presentation.badge)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Don’t Sleep. \(model.presentation.title)")
                .help("Don’t Sleep — \(model.presentation.title)")
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button(model.presentation.quitTitle) { Task { await model.requestQuit() } }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    static var allowTermination = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        Self.model?.startMonitoring()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.allowTermination { return .terminateNow }
        Task { await Self.model?.requestQuit() }
        return .terminateCancel
    }
}

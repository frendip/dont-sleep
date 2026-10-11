import AppKit
import DontSleepIPC

@main
@MainActor enum DontSleepApp {
    private static var lifetimeLock: InstanceLock?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
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
            print("Don’t Sleep: native AppKit entry point loaded. No service connection or power change was made.")
            exit(0)
        }
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.dontsleep.app", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let lock = try InstanceLock.acquire(at: directory.appendingPathComponent("instance.lock")) else {
                if let pid = InstanceGate.existingPID(current: getpid(), bundleID: Bundle.main.bundleIdentifier, processes: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.bundleIdentifier) }) { ReopenRequest.send(to: pid) }
                exit(0)
            }
            Self.lifetimeLock = lock
        } catch { fputs("Cannot acquire Don’t Sleep instance lock: \(error)\n", stderr); exit(1) }
        let model = AppModel(client: XPCServiceClient()) {
            AppDelegate.allowTermination = true
            NSApplication.shared.terminate(nil)
        }
        AppDelegate.model = model
        let delegate = AppDelegate()
        app.delegate = delegate
        // Keep one owner for application lifetime. SwiftUI is hosted only in our
        // controls window; there is no Settings scene for macOS to open/restore.
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var model: AppModel?
    static var allowTermination = false
    private var controls: ControlsWindowController?
    private var statusMenu: NativeStatusMenuController?
    private var reopenObserver: NSObjectProtocol?
    override init() {
        super.init()
        // This notification can only bring UI forward. It cannot enable a mode or bypass the quit gate.
        reopenObserver = DistributedNotificationCenter.default().addObserver(forName: ReopenRequest.name, object: String(getpid()), queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.showControls() }
        }
    }
    deinit { if let reopenObserver { DistributedNotificationCenter.default().removeObserver(reopenObserver) } }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        configureApplicationMenu()
        if let model = Self.model {
            statusMenu = NativeStatusMenuController(model: model, onOpenWindow: { [weak self] in self?.showControls() })
            model.startMonitoring()
        }
        showControls()
    }
    func configureApplicationMenu() {
        let main = NSMenu()
        let application = NSMenu(title: "Don’t Sleep")
        let rootItem = NSMenuItem()
        rootItem.submenu = application
        main.addItem(rootItem)
        let open = NSMenuItem(title: "Открыть окно…", action: #selector(openControls), keyEquivalent: "o")
        open.target = self
        open.keyEquivalentModifierMask = .command
        application.addItem(open)
        application.addItem(.separator())
        let quit = NSMenuItem(title: Self.model?.presentation.quitTitle ?? "Выйти", action: #selector(requestQuit), keyEquivalent: "q")
        quit.target = self
        quit.keyEquivalentModifierMask = .command
        application.addItem(quit)
        NSApp.mainMenu = main
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(requestQuit) {
            menuItem.title = Self.model?.presentation.quitTitle ?? "Выйти"
        }
        return true
    }
    @objc private func openControls() { showControls() }
    @objc private func requestQuit() { Task { await Self.model?.requestQuit() } }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showControls()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    private func showControls() {
        guard let model = Self.model else { return }
        if controls == nil { controls = ControlsWindowController(model: model) }
        controls?.showControls()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.allowTermination { return .terminateNow }
        Task { await Self.model?.requestQuit() }
        return .terminateCancel
    }
}

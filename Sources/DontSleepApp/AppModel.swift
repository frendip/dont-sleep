import Foundation
import SwiftUI
import Security
import UserNotifications
import DontSleepCore
import DontSleepIPC
import DontSleepPlatform

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: SessionSnapshot?
    @Published private(set) var connected = false
    @Published private(set) var setupRequired = false
    @Published private(set) var busy = false
    @Published private(set) var installing = false
    @Published private(set) var serviceTime: UInt64 = 0
    @Published private(set) var pendingTitle: String?
    @Published var setupError: String?
    @Published private(set) var lastStopReason: SessionIssue?
    @Published private var refreshingPowerOnReveal = false
    private let client: ServiceClient
    private let activity: ActivityLease
    private let onTerminate: () -> Void
    private let noInstallationExists: () -> Bool
    private var quitGate = QuitGate()
    @Published private(set) var preferredMode: Mode = .permanent
    private var provenNeverInstalled = false
    private var stopRequested = false
    private var stopIntent = false
    private var ownsSession = false
    private var needsRecovery = false
    private var recoveryStopSent = false
    private var terminated = false
    private var inFlight = false
    private var refreshPending = false
    private var pendingStart: Mode?
    enum MenuSurface: Hashable { case menu, window }
    private var visibleSurfaces: Set<MenuSurface> = []
    private var menuVisible = false
    private var lastResponseTime: UInt64 = 0
    private var receivedAt = ContinuousClock.now
    private var lastHeartbeatAt = ContinuousClock.now
    private var monitor: Task<Void, Never>?
    private var monitorRole: Int?
    private var displayTicker: Task<Void, Never>?
    private var powerObservation: PowerObservation?

    init(client: ServiceClient, activity: ActivityLease = ActivityLease(), noInstallationExists: @escaping () -> Bool = ServiceInstaller.noInstallationExists, onTerminate: @escaping () -> Void) {
        self.client = client; self.activity = activity; self.noInstallationExists = noInstallationExists; self.onTerminate = onTerminate
    }
    var presentation: MenuPresentation {
        var result = MenuPresentation(snapshot: snapshot, serviceTime: serviceTime, connected: connected,
                                      operationPending: busy || installing || quitGate.requested || stopIntent || needsRecovery || pendingStart != nil)
        result.selectedMode = preferredMode
        result.refreshingPower = refreshingPowerOnReveal
        result.setupRequired = setupRequired
        result.setupActionAvailable = setupRequired || !connected
        result.previousStopReason = lastStopReason
        let recoveringKnownActive = connected && (snapshot?.state == .active || snapshot?.state == .enabling) && (needsRecovery || stopIntent)
        result.pendingTitle = pendingTitle ?? (recoveringKnownActive ? "Восстановление сна…" : nil)
        result.setupBusy = busy || installing
        result.canQuitWithoutService = provenNeverInstalled && !installing
        return result
    }
    func startMonitoring() {
        powerObservation = try? NativePowerMonitor().observeChanges { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }
    func setMenuVisible(_ visible: Bool, source: MenuSurface = .menu) {
        if visible { visibleSurfaces.insert(source) } else { visibleSurfaces.remove(source) }
        let anyVisible = !visibleSurfaces.isEmpty
        guard menuVisible != anyVisible else { return }
        menuVisible = anyVisible
        displayTicker?.cancel(); displayTicker = nil
        if menuVisible {
            displayTicker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    if self.inFlight || (self.snapshot?.state == .active && self.snapshot?.session?.deadline != nil) { self.updateClock() }
                }
            }
        }
        if menuVisible {
            // Hidden OFF does not poll. Revalidate its healthy cached power without
            // briefly announcing a failure caused only by advancing the display clock.
            // The current clock still blocks starts until fresh power is available.
            refreshingPowerOnReveal = presentation.badge == .none && presentation.banner == nil
            updateClock()
            Task { await refresh() }
        }
        reconcileMonitoring()
    }
    private func reconcileMonitoring() {
        guard !terminated else { monitor?.cancel(); monitor = nil; monitorRole = nil; return }
        let active = connected && snapshot?.state == .active && ownsSession && !quitGate.requested && !stopIntent
        let recovering = needsRecovery || quitGate.requested || snapshot?.state == .restoring || snapshot?.state == .failed
        let role = (menuVisible ? 1 : 0) | (active ? 2 : 0) | (recovering ? 4 : 0)
        if monitorRole == role, monitor != nil { return }
        monitor?.cancel(); monitor = nil; monitorRole = role
        // Verified OFF with a closed menu has no polling or timer task.
        guard role != 0 else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let renewable = self.connected && self.ownsSession && self.snapshot?.state == .active && !self.quitGate.requested && !self.stopIntent
                // Visible power expires after 5 seconds. Refresh at 4 to leave room for
                // sampling/response timestamps straddling a second; hidden heartbeat stays at 5.
                let cadence: Duration = .seconds(self.menuVisible ? 4 : 5)
                let interval: Duration
                if renewable {
                    interval = self.inFlight ? .seconds(1) : max(.milliseconds(1), cadence - self.lastHeartbeatAt.duration(to: .now))
                } else { interval = self.menuVisible && recovering ? .seconds(1) : cadence }
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                if self.menuVisible { self.updateClock() }
                let mayRenew = self.connected && self.ownsSession && self.snapshot?.state == .active && !self.quitGate.requested && !self.stopIntent
                if mayRenew && self.lastHeartbeatAt.duration(to: .now) >= cadence, let identity = self.snapshot?.session?.identity {
                    // Capture UI responsiveness before any nonisolated async executor hop.
                    let issuedAt = PlatformClock.now()
                    await self.call {
                        self.lastHeartbeatAt = .now
                        return try await self.client.heartbeat(identity: identity, issuedAt: issuedAt)
                    }
                } else if !mayRenew {
                    await self.refresh()
                }
            }
        }
    }
    func refresh() async {
        if inFlight { refreshPending = true; return }
        await call { try await self.client.status() }
    }
    func select(_ mode: Mode) async {
        guard presentation.allowsModes else { return }
        preferredMode = mode
    }
    func toggle(_ enabled: Bool) async {
        if enabled {
            guard presentation.allowsModes, !terminated else { return }
            if inFlight {
                // Keep background reads visually quiet; serialize an explicit start behind them.
                pendingStart = preferredMode
                objectWillChange.send()
                return
            }
            await startSelectedMode(preferredMode)
        } else {
            guard connected, snapshot?.state == .active, !quitGate.requested else { return }
            stopIntent = true; activity.setActive(false); objectWillChange.send()
            if !inFlight { await stopForToggle() }
        }
    }
    private func startSelectedMode(_ mode: Mode) async {
        let issuedAt = PlatformClock.now()
        ownsSession = true; lastHeartbeatAt = .now
        await call(title: "Включение…") { try await self.client.start(mode: mode, issuedAt: issuedAt) }
    }
    private func stopForToggle() async {
        stopIntent = false; recoveryStopSent = true; ownsSession = false; needsRecovery = true
        await call(title: "Восстановление сна…") { try await self.client.stop() }
    }
    func requestQuit() async {
        guard quitGate.request() else { return }
        pendingStart = nil
        activity.setActive(false)
        if provenNeverInstalled && snapshot == nil && !installing && noInstallationExists() {
            terminated = true; monitor?.cancel(); onTerminate(); return
        }
        objectWillChange.send()
        if !inFlight { await stopForQuit() }
    }
    private func stopForQuit() async {
        guard !stopRequested else { return }
        stopRequested = true; stopIntent = false
        await call(title: "Восстановление сна…") { try await self.client.stop() }
    }
    private func call(title: String? = nil, _ operation: () async throws -> ServiceResponse) async {
        guard !inFlight, !terminated else { return }
        inFlight = true
        if title != nil { busy = true; pendingTitle = title }
        var acceptedResponse = false
        do { acceptedResponse = accept(try await operation()) }
        catch {
            connected = false; activity.setActive(false)
            if ownsSession {
                // A lost start/heartbeat reply cannot prove ownership or a current lease.
                // Keep observing even with all UI hidden, and restore any surviving session.
                ownsSession = false; needsRecovery = true; recoveryStopSent = false
            }
            if snapshot == nil {
                provenNeverInstalled = noInstallationExists()
                // Missing protected files may arrive as a PlatformError before XPC starts.
                if provenNeverInstalled { setupRequired = true }
                
            }
        }
        // A reply (including a rejected one) or transport timeout ends revalidation.
        refreshingPowerOnReveal = false
        inFlight = false
        if busy { busy = false }
        if pendingTitle != nil { pendingTitle = nil }
        if quitGate.requested && provenNeverInstalled && snapshot == nil && !installing && noInstallationExists() && !terminated {
            terminated = true; monitor?.cancel(); displayTicker?.cancel(); onTerminate(); return
        }
        let requestedStart = pendingStart
        pendingStart = nil
        if requestedStart != nil { objectWillChange.send() }
        if quitGate.requested && !stopRequested { await stopForQuit() }
        else if stopIntent { await stopForToggle() }
        else if let mode = requestedStart {
            // A low battery, lost connection, or rejected response cancels the queued start.
            if acceptedResponse && !terminated && presentation.allowsModes { await startSelectedMode(mode) }
        }
        else if refreshPending && !terminated { refreshPending = false; await refresh() }
        reconcileMonitoring()
    }
    private func accept(_ response: ServiceResponse) -> Bool {
        guard response.protocolVersion == ServiceProtocol.version, response.serviceTime >= lastResponseTime else { return false }
        let previousIssue = snapshot?.issue
        provenNeverInstalled = false
        lastResponseTime = response.serviceTime; serviceTime = response.serviceTime; receivedAt = .now
        snapshot = response.snapshot; lastStopReason = response.lastStopReason
        connected = true; setupRequired = response.snapshot.state == .setupRequired
        if response.snapshot.verifiedOff {
            ownsSession = false; needsRecovery = false; recoveryStopSent = false
        } else if !ownsSession && !quitGate.requested {
            needsRecovery = true
            if !recoveryStopSent { stopIntent = true }
        }
        activity.setActive(connected && ownsSession && response.snapshot.state == .active && !quitGate.requested && !stopIntent && !needsRecovery)
        if response.snapshot.issue == .lowBattery && previousIssue != .lowBattery { LowBatteryNotifications.notify(state: response.snapshot.state) }
        if stopRequested && quitGate.canTerminate(after: response.snapshot) && !terminated {
            terminated = true; monitor?.cancel(); onTerminate()
        }
        return true
    }
    private func updateClock() {
        let elapsed = max(0, receivedAt.duration(to: .now).components.seconds)
        let addition = lastResponseTime.addingReportingOverflow(UInt64(elapsed))
        serviceTime = addition.overflow ? .max : addition.partialValue
    }
    func installService() async {
        guard setupRequired || !connected, !busy, !installing, !inFlight else { return }
        installing = true; setupError = nil
        do { try await ServiceInstaller.install(); await LowBatteryNotifications.requestPermission() }
        catch { setupError = error.localizedDescription }
        installing = false
        await refresh()
    }
}

enum ServiceInstaller {
    static func noInstallationExists() -> Bool {
        let paths = ["/Library/Application Support/DontSleep", "/Library/LaunchDaemons/local.dontsleep.controller.plist", "/Library/LaunchDaemons/local.dontsleep.watchdog.plist"]
        return paths.allSatisfy { path in var info = stat(); return lstat(path, &info) == -1 && errno == ENOENT }
    }
    static func prepareCommand() throws -> String {
        guard let script = Bundle.main.url(forResource: "install-helpers", withExtension: "sh"), getuid() >= 501,
              Bundle.main.bundleURL.pathExtension == "app" else { throw SetupError.bundleRequired }
        var liveCode: SecCode?
        guard SecCodeCopySelf([], &liveCode) == errSecSuccess, let liveCode else { throw SetupError.identity }
        var info: CFDictionary?
        // Security documents that this API accepts a dynamic SecCode object despite its C const-pointer signature.
        let dynamicCode = unsafeBitCast(liveCode, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(dynamicCode, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSDynamicInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any], let hash = signing[kSecCodeInfoUnique as String] as? Data else { throw SetupError.identity }
        let liveHash = hash.map { String(format: "%02x", $0) }.joined()
        var exactLiveRequirement: SecRequirement?
        let requirementText = "cdhash H\"" + liveHash + "\""
        guard SecRequirementCreateWithString(requirementText as CFString, [], &exactLiveRequirement) == errSecSuccess,
              let exactLiveRequirement, SecCodeCheckValidity(liveCode, [], exactLiveRequirement) == errSecSuccess else { throw SetupError.identity }
        let shell = try InstallerProgram.command(program: Data(contentsOf: script), digest: InstallerProgram.pinnedSHA256,
                                                 appPath: Bundle.main.bundleURL.path, uid: getuid(), liveHash: liveHash)
        return shell
    }
    static func install() async throws {
        let shell = try prepareCommand()
        let appleScript = "do shell script " + appleQuote(shell) + " with administrator privileges"
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", appleScript]
                    process.standardError = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
                    try process.run(); process.waitUntilExit()
                    guard process.terminationStatus == 0 else { throw SetupError.cancelledOrFailed }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func appleQuote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    enum SetupError: LocalizedError {
        case bundleRequired, cancelledOrFailed, identity
        var errorDescription: String? {
            switch self {
            case .bundleRequired: return "Откройте Don’t Sleep из установленного приложения в «Программах»."
            case .cancelledOrFailed: return "Настройка не завершена. Нажмите «Настроить…», чтобы повторить системный запрос."
            case .identity: return "Не удалось проверить подпись запущенного приложения. Установите согласованную сборку заново."
            }
        }
    }
}

enum LowBatteryNotifications {
    static func requestPermission() async { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
    static func notify(state: SessionState) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Низкий заряд"
            content.body = "Заряд 20% или ниже. Подключите зарядку, чтобы включить режим." + (state == .off ? "" : " Сон ещё не подтверждён; восстанавливаем настройки.")
            center.add(UNNotificationRequest(identifier: "dontsleep.low-battery", content: content, trigger: nil))
        }
    }
}

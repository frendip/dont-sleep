import Foundation
import DontSleepCore

struct MenuPresentation {
    let snapshot: SessionSnapshot?
    let serviceTime: UInt64
    let connected: Bool
    let operationPending: Bool
    var selectedMode: Mode
    var setupRequired = false
    var canQuitWithoutService = false
    var setupActionAvailable = false
    var setupBusy = false
    var previousStopReason: SessionIssue?
    var pendingTitle: String?

    init(snapshot: SessionSnapshot?, serviceTime: UInt64, connected: Bool = true, operationPending: Bool = false) {
        self.selectedMode = snapshot?.selectedMode ?? .permanent
        self.snapshot = snapshot; self.serviceTime = serviceTime
        self.connected = connected; self.operationPending = operationPending
    }
    private var freshPower: PowerSnapshot? {
        guard connected, let power = snapshot?.power, power.source != .unknown,
              power.sampledAt <= serviceTime, serviceTime - power.sampledAt <= SessionEngine.powerFreshnessSeconds,
              power.percent.map({ (0...100).contains($0) }) ?? true else { return nil }
        return power
    }
    var title: String {
        if let pendingTitle { return pendingTitle }
        if setupRequired || snapshot?.state == .setupRequired { return "Нужна настройка" }
        guard connected, let snapshot else { return "Не удалось проверить состояние" }
        switch snapshot.state {
        case .off: return "Выключено"
        case .active: return "Включено"
        case .enabling: return "Включение…"
        case .restoring: return "Восстановление сна…"
        case .failed: return snapshot.issue == .restoreFailed ? "Сон не восстановлен" : "Не удалось включить режим"
        case .setupRequired: return "Нужна настройка"
        }
    }
    var charge: String { freshPower?.percent.map { "Заряд \($0)%" } ?? "Заряд —" }
    var onAC: Bool { freshPower?.source == .ac }
    var remaining: String? {
        guard connected, snapshot?.state == .active, let deadline = snapshot?.session?.deadline else { return nil }
        let seconds = deadline > serviceTime ? deadline - serviceTime : 0
        let time = seconds >= 3_600
            ? String(format: "%llu:%02llu:%02llu", seconds / 3_600, seconds % 3_600 / 60, seconds % 60)
            : String(format: "%llu:%02llu", seconds / 60, seconds % 60)
        return "Осталось \(time)"
    }
    var allowsModes: Bool { snapshot?.verifiedOff == true && connected && !operationPending && !setupRequired && (snapshot?.canEnable(at: serviceTime) ?? false) }
    var showsSwitch: Bool {
        connected && !setupRequired && snapshot != nil && snapshot?.state != .failed && snapshot?.state != .setupRequired
    }
    var switchOn: Bool { connected && snapshot?.state == .active }
    var bolt: Bool { connected && snapshot?.state == .active }
    var badge: StatusBadge {
        if setupRequired || snapshot?.state == .setupRequired { return .warning }
        guard connected, let snapshot else { return .error }
        if snapshot.state == .failed { return .error }
        if snapshot.issue == .lowBattery || freshPower?.blockingIssue(at: serviceTime) == .lowBattery { return .warning }
        if freshPower == nil || snapshot.issue == .servicesUnavailable { return .warning }
        return .none
    }
    var quitTitle: String { (canQuitWithoutService || (connected && snapshot?.verifiedOff == true)) ? "Выйти" : "Выключить и выйти" }
    var banner: StatusBanner? {
        if setupRequired || snapshot?.state == .setupRequired {
            return StatusBanner(title: "Нужна настройка", detail: "Для управления сном нужен служебный компонент с правами администратора.", severity: .warning)
        }
        guard connected, let snapshot else {
            return StatusBanner(title: "Служба недоступна", detail: "Не удалось проверить состояние сна. Проверьте служебный компонент. Выход — после проверки восстановления.", severity: .error)
        }
        if snapshot.state == .failed {
            return StatusBanner(title: snapshot.issue == .restoreFailed ? "Ошибка восстановления" : "Не удалось включить режим", detail: "Сон ещё не подтверждён. Выход — после восстановления.", severity: .error)
        }
        if snapshot.issue == .lowBattery || freshPower?.blockingIssue(at: serviceTime) == .lowBattery {
            let suffix = snapshot.verifiedOff ? "" : " Восстанавливаем сон."
            return StatusBanner(title: "Низкий заряд", detail: "При 20% и ниже режим недоступен. Подключите зарядку." + suffix, severity: .warning)
        }
        if freshPower == nil || freshPower?.blockingIssue(at: serviceTime) == .powerUnavailable {
            return StatusBanner(title: "Нет данных о питании", detail: "Включение недоступно до получения актуальных данных.", severity: .warning)
        }
        if snapshot.issue == .applyFailed {
            return StatusBanner(title: "Не удалось включить режим", detail: "Проверьте настройки сна и повторите попытку.", severity: .error)
        }
        if snapshot.verifiedOff, let previousStopReason {
            switch previousStopReason {
            case .leaseExpired, .servicesUnavailable:
                return StatusBanner(title: "Предыдущий режим завершён", detail: "Работа приложения или службы была прервана. Сон восстановлен. Режим не возобновлялся.", severity: .warning)
            default: break
            }
        }
        return nil
    }
}
enum StatusBadge { case none, warning, error }
struct StatusBanner { let title: String; let detail: String; let severity: StatusBadge }

struct QuitGate {
    private(set) var requested = false
    mutating func request() -> Bool {
        guard !requested else { return false }
        requested = true; return true
    }
    func canTerminate(after snapshot: SessionSnapshot?) -> Bool { requested && snapshot?.verifiedOff == true }
}

extension Mode {
    var title: String {
        switch self {
        case .permanent: return "Без таймера"
        case .fiveMinutes: return "На 5 минут"
        case .fifteenMinutes: return "На 15 минут"
        case .thirtyMinutes: return "На 30 минут"
        case .oneHour: return "На 1 час"
        case .fourHours: return "На 4 часа"
        case .eightHours: return "На 8 часов"
        }
    }
}

import Foundation
import IOKit

public enum PlatformError: Error, Equatable, CustomStringConvertible {
    case unsafeFile(String), invalidJournal, conflictingSession, invalidPowerState, baselineDisabled
    case commandFailed(Int32), timedOut, childNotReaped, writerBusy, writerNotHeld, invalidTrust, verificationFailed
    case system(String, Int32)
    public var description: String {
        switch self {
        case .unsafeFile(let value): return "Unsafe protected file: " + value
        case .system(let operation, let code): return "\(operation): errno \(code)"
        case .commandFailed(let code): return "System command exited \(code)"
        case .invalidJournal: return "Recovery journal is invalid"
        case .conflictingSession: return "Conflicting recovery session"
        case .invalidPowerState: return "Cannot read reliable power state"
        case .baselineDisabled: return "Sleep is already disabled or baseline conflicts"
        case .timedOut: return "System command timed out and was reaped"
        case .childNotReaped: return "System child termination is unconfirmed"
        case .writerBusy: return "Another writer or its child holds the lock"
        case .writerNotHeld: return "Power writer lock is not held"
        case .invalidTrust: return "Installed trust configuration is invalid"
        case .verificationFailed: return "System power readback did not match"
        }
    }
}

public struct SleepSnapshot: Codable, Equatable, Sendable {
    public let actualDisabled: Bool
    public let persistedDisabled: Bool
    public init(actualDisabled: Bool, persistedDisabled: Bool) {
        self.actualDisabled = actualDisabled; self.persistedDisabled = persistedDisabled
    }
    public func validateBaseline() throws {
        guard !actualDisabled && !persistedDisabled else { throw PlatformError.baselineDisabled }
    }
}

public protocol SleepBackend {
    func read() throws -> SleepSnapshot
    func applyDisabled() throws
    func restore(_ snapshot: SleepSnapshot) throws
    func verify(_ snapshot: SleepSnapshot) throws -> Bool
}

/// Production writes require a lifetime-held writer lock. Callers must durably
/// journal the baseline before applyDisabled; this layer never guesses it.
public final class PMSetSleepBackend: SleepBackend {
    private let runner: SystemCommandRunning
    private let writerLock: WriterLock?
    private let actualState: () throws -> Bool
    public init(runner: SystemCommandRunning = BoundedProcess(), writerLock: WriterLock) {
        self.runner = runner; self.writerLock = writerLock; self.actualState = Self.readActual
    }
    // Dependency injection is module-internal, so production cannot accidentally
    // construct a writable backend without a lock.
    init(runner: SystemCommandRunning, actualState: @escaping () throws -> Bool) {
        self.runner = runner; self.writerLock = nil; self.actualState = actualState
    }
    public func read() throws -> SleepSnapshot {
        let result = try runner.run(.readSettings, inheritingLockFD: nil)
        guard result.exitCode == 0 else { throw PlatformError.commandFailed(result.exitCode) }
        guard let text = String(data: result.output, encoding: .utf8) else { throw PlatformError.invalidPowerState }
        return try SleepSnapshot(actualDisabled: actualState(), persistedDisabled: Self.parsePersisted(text))
    }
    public func applyDisabled() throws {
        try read().validateBaseline()
        try write(true)
        guard try read() == SleepSnapshot(actualDisabled: true, persistedDisabled: true) else { throw PlatformError.verificationFailed }
    }
    public func restore(_ snapshot: SleepSnapshot) throws {
        try snapshot.validateBaseline()
        try write(snapshot.persistedDisabled)
        guard try verify(snapshot) else { throw PlatformError.verificationFailed }
    }
    public func verify(_ snapshot: SleepSnapshot) throws -> Bool { try read() == snapshot }
    private func write(_ disabled: Bool) throws {
        if let writerLock, !writerLock.isHeld { throw PlatformError.writerNotHeld }
        let result = try runner.run(.setDisabled(disabled), inheritingLockFD: writerLock?.descriptor)
        guard result.exitCode == 0 else { throw PlatformError.commandFailed(result.exitCode) }
    }
    public static func parsePersisted(_ text: String) throws -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace) }
            .filter { !$0.isEmpty }
        let matches = lines.filter { $0.first == "SleepDisabled" }
        if matches.isEmpty {
            // pmset prints this header only after reading the system settings dictionary.
            // powerd treats an absent SleepDisabled key as false. Require the next
            // section too, so empty, failed or incomplete output cannot become a baseline.
            let systemHeaders = lines.indices.filter { lines[$0] == ["System-wide", "power", "settings:"] }
            let liveHeaders = lines.indices.filter { lines[$0] == ["Currently", "in", "use:"] }
            guard systemHeaders == [0], liveHeaders.count == 1,
                  let live = liveHeaders.first, live > 0, live + 1 < lines.count,
                  lines[1..<live].allSatisfy({ row in
                      row.count == 2 && ["DestroyFVKeyOnStandby", "VACTDisabled"].contains(row[0])
                          && (row[1] == "0" || row[1] == "1")
                  }) else { throw PlatformError.invalidPowerState }
            return false
        }
        guard matches.count == 1, matches[0].count == 2 else { throw PlatformError.invalidPowerState }
        switch matches[0][1] { case "0": return false; case "1": return true; default: throw PlatformError.invalidPowerState }
    }
    public static func readActual() throws -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { throw PlatformError.invalidPowerState }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              CFGetTypeID(value) == CFBooleanGetTypeID() else { throw PlatformError.invalidPowerState }
        return CFBooleanGetValue((value as! CFBoolean))
    }
}

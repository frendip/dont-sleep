import Foundation
import DontSleepCore
import DontSleepPlatform

/// All methods are confined to the writer's serial queue. The writer owns its
/// lifetime flock; Controller never touches this type or the power backend.
public final class RecoveryRuntime {
    private var engine = SessionEngine(servicesReady: false)
    private let backend: SleepBackend
    private let journal: RecoveryJournal
    private let bootID: String
    private var record: RecoveryRecord?
    private var lastGuard: UInt64?
    private var maintenance = false
    private var retryAt: UInt64?
    private var lastStopReason: SessionIssue?
    public init(backend: SleepBackend, journal: RecoveryJournal, bootID: String, now: UInt64 = 0) throws {
        self.backend = backend; self.journal = journal; self.bootID = bootID
        record = try journal.load()
        lastStopReason = record?.stopReason.flatMap(SessionIssue.init(rawValue:))
        if let record, record.phase != .restored {
            lastStopReason = lastStopReason ?? .servicesUnavailable
            deliver(.bootRecovery(.init(sessionID: record.sessionID, generation: record.generation)), now: now)
        } else { deliver(.recoveryChecked, now: now) }
    }
    public func response(now: UInt64) -> ServiceResponse { .init(snapshot: engine.snapshot, serviceTime: now, lastStopReason: lastStopReason) }
    @discardableResult
    public func process(_ command: ServiceCommand, now: UInt64, power: PowerSnapshot) -> ServiceResponse {
        // Every request is from the authenticated Controller. Guard health does
        // not renew the UI lease; only .heartbeat with matching identity does.
        lastGuard = now
        deliver(.power(power), now: now)
        deliver(.servicesReady(!maintenance), now: now)
        switch command {
        case .health, .status: deliver(.tick, now: now)
        case .start(let mode): deliver(.enable(mode: mode, sessionID: UUID()), now: now)
        case .heartbeat(let identity): deliver(.heartbeat(identity), now: now)
        case .stop: deliver(engine.snapshot.state == .failed ? .retryRestore : .disable, now: now)
        case .maintenance:
            maintenance = true
            deliver(.servicesReady(false), now: now)
            deliver(engine.snapshot.state == .failed ? .retryRestore : .disable, now: now)
        }
        return response(now: now)
    }
    public func tick(now: UInt64, power: PowerSnapshot) {
        deliver(.power(power), now: now)
        let guarded = lastGuard.map { now >= $0 && now - $0 < 15 } ?? false
        deliver(.servicesReady(guarded && !maintenance), now: now)
        deliver(.tick, now: now)
        if let retryAt, now >= retryAt, engine.snapshot.state == .failed { deliver(.retryRestore, now: now) }
    }
    public var nextDeadline: UInt64? {
        if engine.snapshot.state == .failed { return retryAt }
        guard let session = engine.snapshot.session, engine.snapshot.state == .active else { return nil }
        return min(session.leaseDeadline, session.deadline ?? UInt64.max)
    }
    private func deliver(_ event: Event, now: UInt64) {
        execute(engine.handle(event, now: now), now: now)
    }
    private func execute(_ effects: [Effect], now: UInt64) {
        for effect in effects {
            switch effect {
            case .apply(let session):
                var applied = false
                do {
                    if let record, record.phase != .restored { throw ServiceTransportError.unavailable }
                    let original = try backend.read()
                    // Do not claim or later undo another actor's existing disable.
                    guard !original.actualDisabled && !original.persistedDisabled else { throw ServiceTransportError.unavailable }
                    let prepared = RecoveryRecord(sessionID: session.identity.sessionID,
                        generation: session.identity.generation, bootID: bootID, phase: .prepared, original: original)
                    lastStopReason = nil
                    record = prepared
                    try journal.persist(prepared)
                    try backend.applyDisabled()
                    applied = try backend.verify(SleepSnapshot(actualDisabled: true, persistedDisabled: true))
                    if applied {
                        var active = prepared; active.phase = .active
                        try journal.persist(active); record = active
                    }
                } catch { applied = false }
                deliver(.applyResult(session.identity, verified: applied), now: now)
            case .restore(let identity):
                lastStopReason = engine.snapshot.issue ?? lastStopReason
                var verified = false
                do {
                    if var pending = record, pending.phase != .restored {
                        pending.phase = .restoring
                        pending.stopReason = lastStopReason?.rawValue
                        try journal.persist(pending); record = pending
                        try backend.restore(pending.original)
                        verified = try backend.verify(pending.original)
                        if verified {
                            try journal.markRestored(sessionID: pending.sessionID)
                            pending.phase = .restored; record = pending
                        }
                    } else {
                        // No mutation was attempted: e.g. an externally disabled
                        // setting rejected activation before creating our record.
                        verified = true
                    }
                } catch { verified = false }
                retryAt = verified ? nil : (now <= UInt64.max - 30 ? now + 30 : UInt64.max)
                deliver(.restoreResult(identity, verified: verified), now: now)
            case .schedule, .cancelSchedule, .terminate: break
            }
        }
    }
}

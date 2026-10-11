import Foundation

public enum Event: Equatable, Sendable {
    case power(PowerSnapshot)
    case servicesReady(Bool)
    /// Successful journal inspection found no unfinished own operation.
    case recoveryChecked
    /// The originating UI confirmation time bounds the lease even after IPC queue delay.
    case enable(mode: Mode, sessionID: UUID, confirmationAt: UInt64? = nil)
    case disable, quit, tick, retryRestore
    case heartbeat(SessionIdentity, confirmationAt: UInt64? = nil)
    case applyResult(SessionIdentity, verified: Bool)
    case restoreResult(SessionIdentity, verified: Bool)
    case bootRecovery(SessionIdentity)
}

public enum Effect: Equatable, Sendable {
    case apply(Session)
    case restore(SessionIdentity)
    case schedule(Session)
    case cancelSchedule
    case terminate
}

/// A deterministic reducer. The host serializes effects and supplies a continuous boot clock.
public struct SessionEngine: Sendable {
    public static let heartbeatIntervalSeconds: UInt64 = 5
    public static let leaseDurationSeconds: UInt64 = 30
    public static let powerFreshnessSeconds: UInt64 = 5
    public private(set) var snapshot: SessionSnapshot
    private var servicesAvailable: Bool
    private var lastNow: UInt64 = 0
    private var generation: UInt64 = 0
    private var terminationEmitted = false
    private var operationSeen = false
    private var activationFailurePending = false

    public init(servicesReady: Bool = true) {
        servicesAvailable = servicesReady
        snapshot = SessionSnapshot(state: servicesReady ? .off : .setupRequired)
    }

    public mutating func handle(_ event: Event, now suppliedNow: UInt64) -> [Effect] {
        let now = max(lastNow, suppliedNow)
        lastNow = now

        // Refresh safety inputs before assessing expiry, so a coalesced fresh sample
        // at the normal polling boundary does not expire the previous sample.
        switch event {
        case .power(let power):
            // Invalid at receipt stays invalid; advancing time cannot validate it.
            guard power.sampledAt <= now else {
                snapshot.power = nil
                break
            }
            if let previous = snapshot.power, previous.sampledAt <= now,
               power.sampledAt <= now, power.sampledAt < previous.sampledAt {
                break
            }
            snapshot.power = power
        case .servicesReady(let ready): servicesAvailable = ready
        default: break
        }

        var effects: [Effect] = []
        if snapshot.state == .active || snapshot.state == .enabling {
            if let issue = stoppingIssue(at: now) {
                effects += beginRestoration(issue: issue)
            }
        }

        switch event {
        case .power, .servicesReady:
            if snapshot.session == nil {
                snapshot.state = servicesAvailable && snapshot.recoveryVerified ? .off : .setupRequired
                snapshot.issue = idleIssue(at: now)
                effects += terminateIfSafe()
            }
        case .recoveryChecked:
            guard snapshot.session == nil else { return effects }
            snapshot.recoveryVerified = true
            snapshot.state = servicesAvailable ? .off : .setupRequired
            snapshot.issue = idleIssue(at: now)
            effects += terminateIfSafe()
        case .enable(let mode, let requestedID, let confirmationAt):
            if snapshot.session == nil {
                snapshot.issue = idleIssue(at: now)
            }
            guard servicesAvailable, snapshot.canEnable(at: now), generation < UInt64.max,
                  now <= UInt64.max - (mode.durationSeconds ?? 0),
                  let confirmedDeadline = leaseDeadline(confirmedAt: confirmationAt, now: now)
            else { return effects }
            let alreadyActive = snapshot.state == .active
            let lease = max(snapshot.session?.leaseDeadline ?? 0, confirmedDeadline)
            let id = alreadyActive ? snapshot.session!.identity.sessionID : requestedID
            generation += 1
            let session = Session(identity: .init(sessionID: id, generation: generation), mode: mode,
                                  deadline: mode.durationSeconds.map { now + $0 },
                                  leaseDeadline: lease)
            snapshot.selectedMode = mode
            snapshot.session = session
            snapshot.recoveryVerified = false
            activationFailurePending = false
            snapshot.issue = nil
            operationSeen = true
            if alreadyActive {
                effects.append(.schedule(session))
            } else {
                snapshot.state = .enabling
                effects.append(.apply(session))
            }
        case .disable:
            effects += beginRestoration(issue: nil)
        case .quit:
            snapshot.quitRequested = true
            effects += beginRestoration(issue: nil)
            effects += terminateIfSafe()
        case .heartbeat(let identity, let confirmationAt):
            guard snapshot.state == .active, let session = snapshot.session,
                  session.identity == identity,
                  let confirmedDeadline = leaseDeadline(confirmedAt: confirmationAt, now: now)
            else { return effects }
            let renewed = Session(identity: identity, mode: session.mode, deadline: session.deadline,
                                  leaseDeadline: max(session.leaseDeadline, confirmedDeadline))
            snapshot.session = renewed
            effects.append(.schedule(renewed))
        case .applyResult(let identity, let verified):
            guard snapshot.state == .enabling, let session = snapshot.session, session.identity == identity
            else { return effects }
            if verified {
                snapshot.state = .active
                effects.append(.schedule(session))
            } else {
                activationFailurePending = true
                effects += beginRestoration(issue: .applyFailed)
            }
        case .restoreResult(let identity, let verified):
            guard snapshot.state == .restoring, snapshot.session?.identity == identity else { return effects }
            if verified {
                snapshot.session = nil
                snapshot.recoveryVerified = true
                snapshot.state = servicesAvailable && snapshot.recoveryVerified ? .off : .setupRequired
                snapshot.issue = idleIssue(at: now)
                effects += terminateIfSafe()
            } else {
                snapshot.state = .failed
                snapshot.issue = .restoreFailed
            }
        case .retryRestore:
            guard snapshot.state == .failed, let session = snapshot.session, generation < UInt64.max
            else { return effects }
            generation += 1
            let identity = SessionIdentity(sessionID: session.identity.sessionID, generation: generation)
            snapshot.session = Session(identity: identity, mode: session.mode, deadline: nil, leaseDeadline: 0)
            snapshot.state = .restoring
            effects.append(.restore(identity))
        case .bootRecovery(let previous):
            guard !operationSeen, snapshot.session == nil else { return effects }
            operationSeen = true
            snapshot.recoveryVerified = false
            generation = previous.generation
            // Recovery does not preserve old-boot deadlines or confirmation leases.
            snapshot.session = Session(identity: previous, mode: .permanent, deadline: nil, leaseDeadline: 0)
            snapshot.state = .enabling
            effects += beginRestoration(issue: nil)
        case .tick: break
        }
        return effects
    }

    private func leaseDeadline(confirmedAt supplied: UInt64?, now: UInt64) -> UInt64? {
        let confirmedAt = supplied ?? now
        guard confirmedAt <= now, now - confirmedAt < Self.leaseDurationSeconds,
              confirmedAt <= UInt64.max - Self.leaseDurationSeconds else { return nil }
        return confirmedAt + Self.leaseDurationSeconds
    }

    private func powerIssue(at now: UInt64) -> SessionIssue? {
        guard let power = snapshot.power else { return .powerUnavailable }
        return power.blockingIssue(at: now)
    }

    private func idleIssue(at now: UInt64) -> SessionIssue? {
        guard servicesAvailable else { return .servicesUnavailable }
        return powerIssue(at: now) ?? (activationFailurePending ? .applyFailed : nil)
    }

    private func stoppingIssue(at now: UInt64) -> SessionIssue? {
        guard servicesAvailable else { return .servicesUnavailable }
        guard let session = snapshot.session else { return .servicesUnavailable }
        if let deadline = session.deadline, now >= deadline { return .timerExpired }
        if now >= session.leaseDeadline { return .leaseExpired }
        return powerIssue(at: now)
    }

    private mutating func beginRestoration(issue: SessionIssue?) -> [Effect] {
        guard snapshot.state == .active || snapshot.state == .enabling, let session = snapshot.session
        else { return [] }
        if generation < UInt64.max { generation += 1 }
        let identity = SessionIdentity(sessionID: session.identity.sessionID, generation: generation)
        snapshot.session = Session(identity: identity, mode: session.mode, deadline: nil, leaseDeadline: 0)
        snapshot.state = .restoring
        snapshot.issue = issue
        return [.cancelSchedule, .restore(identity)]
    }

    private mutating func terminateIfSafe() -> [Effect] {
        guard snapshot.quitRequested, snapshot.verifiedOff, !terminationEmitted else { return [] }
        terminationEmitted = true
        return [.terminate]
    }
}

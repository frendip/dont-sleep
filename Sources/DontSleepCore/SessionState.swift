import Foundation

public enum SessionState: String, Codable, Sendable {
    case off, enabling, active, restoring, failed, setupRequired
}

public enum SessionIssue: String, Codable, Sendable {
    case lowBattery, powerUnavailable, servicesUnavailable, applyFailed, restoreFailed, leaseExpired, timerExpired
}

public struct SessionIdentity: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let generation: UInt64
    public init(sessionID: UUID, generation: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
    }
}

public struct Session: Codable, Equatable, Sendable {
    public let identity: SessionIdentity
    public let mode: Mode
    public let deadline: UInt64?
    public let leaseDeadline: UInt64
    public init(identity: SessionIdentity, mode: Mode, deadline: UInt64?, leaseDeadline: UInt64) {
        self.identity = identity
        self.mode = mode
        self.deadline = deadline
        self.leaseDeadline = leaseDeadline
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public internal(set) var state: SessionState
    public internal(set) var selectedMode: Mode
    public internal(set) var session: Session?
    public internal(set) var power: PowerSnapshot?
    public internal(set) var issue: SessionIssue?
    public internal(set) var quitRequested: Bool
    /// Journal inspection or verified restoration established absence of an unfinished own operation.
    public internal(set) var recoveryVerified: Bool

    public init(state: SessionState, selectedMode: Mode = .permanent, session: Session? = nil,
                power: PowerSnapshot? = nil, issue: SessionIssue? = nil, quitRequested: Bool = false,
                recoveryVerified: Bool? = nil) {
        self.state = state
        self.selectedMode = selectedMode
        self.session = session
        self.power = power
        self.issue = issue
        self.quitRequested = quitRequested
        self.recoveryVerified = recoveryVerified ?? (state == .off)
    }

    public var verifiedOff: Bool { recoveryVerified && session == nil && (state == .off || state == .setupRequired) }
    public func canEnable(at now: UInt64) -> Bool {
        guard !quitRequested, state == .active || (state == .off && recoveryVerified), let power else { return false }
        return power.blockingIssue(at: now) == nil
    }
}

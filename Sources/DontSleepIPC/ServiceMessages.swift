import Foundation
import DontSleepCore
import DontSleepPlatform

public enum ServiceProtocol {
    public static let version = 2
    public static let requestLifetimeSeconds: UInt64 = 10
}

public enum ServiceTransportError: String, Error, Codable { case unavailable, invalidMessage, unauthorized, timedOut }
public enum ServiceCommand: Codable, Equatable {
    case status
    case start(Mode)
    case heartbeat(SessionIdentity)
    case stop
    case health
    case maintenance
}
public struct ServiceRequest: Codable {
    public let protocolVersion: Int
    public let command: ServiceCommand
    public let nonce: UUID
    public let sequence: UInt64
    public let issuedAt: UInt64
    public let expiresAt: UInt64
    public init(protocolVersion: Int = ServiceProtocol.version, command: ServiceCommand, nonce: UUID, sequence: UInt64,
                issuedAt: UInt64 = PlatformClock.now(), expiresAt: UInt64? = nil) {
        self.protocolVersion = protocolVersion; self.command = command; self.nonce = nonce; self.sequence = sequence
        self.issuedAt = issuedAt
        let expiry = issuedAt.addingReportingOverflow(ServiceProtocol.requestLifetimeSeconds)
        self.expiresAt = expiresAt ?? (expiry.overflow ? issuedAt : expiry.partialValue)
    }
    /// A new connection needs its own replay identity, but must retain the originating UI's deadline.
    public func forwarded(nonce: UUID, sequence: UInt64) -> ServiceRequest {
        .init(protocolVersion: protocolVersion, command: command, nonce: nonce, sequence: sequence,
              issuedAt: issuedAt, expiresAt: expiresAt)
    }
    public func validateForExecution(at now: UInt64) throws {
        guard protocolVersion == ServiceProtocol.version,
              expiresAt > issuedAt, expiresAt - issuedAt <= ServiceProtocol.requestLifetimeSeconds,
              now >= issuedAt else { throw ServiceTransportError.invalidMessage }
        guard now < expiresAt else { throw ServiceTransportError.timedOut }
    }

}
public struct ServiceResponse: Codable {
    public let protocolVersion: Int
    public let snapshot: SessionSnapshot
    public let serviceTime: UInt64
    public let lastStopReason: SessionIssue?
    public init(snapshot: SessionSnapshot, serviceTime: UInt64, lastStopReason: SessionIssue? = nil) {
        protocolVersion = ServiceProtocol.version; self.snapshot = snapshot; self.serviceTime = serviceTime; self.lastStopReason = lastStopReason
    }
}
struct WireReply: Codable { let response: ServiceResponse?; let error: ServiceTransportError? }
public final class RequestGate {
    public static let maximumBytes = 16_384
    private var nonce: UUID?
    private var sequence: UInt64 = 0
    private let lock = NSLock()
    public init() {}
    public func decode(_ data: Data, now: UInt64 = PlatformClock.now()) throws -> ServiceRequest {
        lock.lock(); defer { lock.unlock() }
        guard data.count <= Self.maximumBytes,
              let request = try? JSONDecoder().decode(ServiceRequest.self, from: data),
              request.protocolVersion == ServiceProtocol.version, request.sequence > sequence,
              nonce == nil || nonce == request.nonce else { throw ServiceTransportError.invalidMessage }
        try request.validateForExecution(at: now)
        nonce = request.nonce; sequence = request.sequence
        return request
    }
}
public protocol ServiceClient: AnyObject {
    func status() async throws -> ServiceResponse
    func start(mode: Mode, issuedAt: UInt64) async throws -> ServiceResponse
    func heartbeat(identity: SessionIdentity, issuedAt: UInt64) async throws -> ServiceResponse
    func stop() async throws -> ServiceResponse
}
public enum ServiceLocations {
    public static let controller = "local.dontsleep.controller"
    public static let watchdog = "local.dontsleep.watchdog"
    public static let root = URL(fileURLWithPath: "/Library/Application Support/DontSleep", isDirectory: true)
    public static let state = root.appendingPathComponent("state", isDirectory: true)
}

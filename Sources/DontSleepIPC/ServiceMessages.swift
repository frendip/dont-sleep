import Foundation
import DontSleepCore

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
    public init(protocolVersion: Int = 1, command: ServiceCommand, nonce: UUID, sequence: UInt64) {
        self.protocolVersion = protocolVersion; self.command = command; self.nonce = nonce; self.sequence = sequence
    }
}
public struct ServiceResponse: Codable {
    public let protocolVersion: Int
    public let snapshot: SessionSnapshot
    public let serviceTime: UInt64
    public let lastStopReason: SessionIssue?
    public init(snapshot: SessionSnapshot, serviceTime: UInt64, lastStopReason: SessionIssue? = nil) {
        protocolVersion = 1; self.snapshot = snapshot; self.serviceTime = serviceTime; self.lastStopReason = lastStopReason
    }
}
struct WireReply: Codable { let response: ServiceResponse?; let error: ServiceTransportError? }
public final class RequestGate {
    public static let maximumBytes = 16_384
    private var nonce: UUID?
    private var sequence: UInt64 = 0
    private let lock = NSLock()
    public init() {}
    public func decode(_ data: Data) throws -> ServiceRequest {
        lock.lock(); defer { lock.unlock() }
        guard data.count <= Self.maximumBytes,
              let request = try? JSONDecoder().decode(ServiceRequest.self, from: data),
              request.protocolVersion == 1, request.sequence > sequence,
              nonce == nil || nonce == request.nonce else { throw ServiceTransportError.invalidMessage }
        nonce = request.nonce; sequence = request.sequence
        return request
    }
}
public protocol ServiceClient: AnyObject {
    func status() async throws -> ServiceResponse
    func start(mode: Mode) async throws -> ServiceResponse
    func heartbeat(identity: SessionIdentity) async throws -> ServiceResponse
    func stop() async throws -> ServiceResponse
}
public enum ServiceLocations {
    public static let controller = "local.dontsleep.controller"
    public static let watchdog = "local.dontsleep.watchdog"
    public static let root = URL(fileURLWithPath: "/Library/Application Support/DontSleep", isDirectory: true)
    public static let state = root.appendingPathComponent("state", isDirectory: true)
}

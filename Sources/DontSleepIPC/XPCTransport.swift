import Foundation
import DontSleepCore
import DontSleepPlatform

@objc public protocol SleepXPCProtocol {
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void)
}

private final class PendingReply {
    private let lock = NSLock()
    private var completion: ((Result<ServiceResponse, Error>) -> Void)?
    init(_ completion: @escaping (Result<ServiceResponse, Error>) -> Void) { self.completion = completion }
    func finish(_ result: Result<ServiceResponse, Error>) {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?(result)
    }
}

public final class XPCChannel {
    private let service: String
    private let peer: TrustRole
    private let queue = DispatchQueue(label: "local.dontsleep.xpc-client")
    private var connection: NSXPCConnection?
    private var nonce = UUID()
    private var sequence: UInt64 = 0
    public init(service: String, peer: TrustRole) { self.service = service; self.peer = peer }
    public func send(_ command: ServiceCommand, completion: @escaping (Result<ServiceResponse, Error>) -> Void) {
        let pending = PendingReply(completion)
        queue.async { [self] in
            do {
                let trust = try TrustPolicy.load()
                let connection: NSXPCConnection
                if let existing = self.connection { connection = existing }
                else {
                    connection = NSXPCConnection(machServiceName: self.service, options: .privileged)
                    trust.configure(connection: connection, peer: self.peer)
                    connection.remoteObjectInterface = NSXPCInterface(with: SleepXPCProtocol.self)
                    connection.invalidationHandler = { [weak self, weak connection] in
                        self?.queue.async { [weak self, weak connection] in
                            if self?.connection === connection { self?.connection = nil }
                        }
                    }
                    connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
                    connection.resume()
                    self.connection = connection; self.nonce = UUID(); self.sequence = 0
                }
                guard self.sequence < UInt64.max else { throw ServiceTransportError.invalidMessage }
                self.sequence += 1
                let request = ServiceRequest(command: command, nonce: self.nonce, sequence: self.sequence)
                let data = try JSONEncoder().encode(request)
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    pending.finish(.failure(error)); connection.invalidate()
                }) as? SleepXPCProtocol else { throw ServiceTransportError.unavailable }
                proxy.request(data) { data in
                    guard trust.validateUID(connection, role: self.peer) else {
                        connection.invalidate(); pending.finish(.failure(ServiceTransportError.unauthorized)); return
                    }
                    guard data.count <= RequestGate.maximumBytes,
                          let envelope = try? JSONDecoder().decode(WireReply.self, from: data) else {
                        pending.finish(.failure(ServiceTransportError.invalidMessage)); return
                    }
                    if let response = envelope.response, response.protocolVersion == 1 { pending.finish(.success(response)) }
                    else { pending.finish(.failure(envelope.error ?? .invalidMessage)) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                    // This is deliberately independent of the service worker queue.
                    pending.finish(.failure(ServiceTransportError.timedOut))
                }
            } catch { pending.finish(.failure(error)) }
        }
    }
    public func send(_ command: ServiceCommand) async throws -> ServiceResponse {
        try await withCheckedThrowingContinuation { continuation in
            send(command) { continuation.resume(with: $0) }
        }
    }
}

public final class XPCServiceClient: ServiceClient {
    private let channel = XPCChannel(service: ServiceLocations.controller, peer: .controller)
    public init() {}
    public func status() async throws -> ServiceResponse { try await channel.send(.status) }
    public func start(mode: Mode) async throws -> ServiceResponse { try await channel.send(.start(mode)) }
    public func heartbeat(identity: SessionIdentity) async throws -> ServiceResponse { try await channel.send(.heartbeat(identity)) }
    public func stop() async throws -> ServiceResponse { try await channel.send(.stop) }
}

public final class AuthenticatedListener: NSObject, NSXPCListenerDelegate {
    public typealias Handler = (ServiceCommand, @escaping (Result<ServiceResponse, Error>) -> Void) -> Void
    private let listener: NSXPCListener
    private let trust: TrustPolicy
    private let allowedPeer: TrustRole
    private let handler: Handler
    public init(service: String, allowedPeer: TrustRole, handler: @escaping Handler) throws {
        self.trust = try TrustPolicy.load(); self.allowedPeer = allowedPeer; self.handler = handler
        listener = NSXPCListener(machServiceName: service)
        super.init()
        trust.configure(listener: listener, allowedPeer: allowedPeer)
        listener.delegate = self
    }
    public func resume() { listener.resume() }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard trust.validateUID(connection, role: allowedPeer) else { return false }
        trust.configure(connection: connection, peer: allowedPeer)
        connection.exportedInterface = NSXPCInterface(with: SleepXPCProtocol.self)
        connection.exportedObject = RequestEndpoint(allowHealth: allowedPeer == .controller, handler: handler)
        connection.resume()
        return true
    }
}

private final class RequestEndpoint: NSObject, SleepXPCProtocol {
    private let gate = RequestGate()
    private let allowHealth: Bool
    private let handler: AuthenticatedListener.Handler
    init(allowHealth: Bool, handler: @escaping AuthenticatedListener.Handler) { self.allowHealth = allowHealth; self.handler = handler }
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        do {
            let request = try gate.decode(data)
            guard allowHealth || (request.command != .health && request.command != .maintenance) else { throw ServiceTransportError.unauthorized }
            handler(request.command) { result in
                let envelope: WireReply
                switch result {
                case .success(let response): envelope = WireReply(response: response, error: nil)
                case .failure(let error): envelope = WireReply(response: nil, error: error as? ServiceTransportError ?? .unavailable)
                }
                reply((try? JSONEncoder().encode(envelope)) ?? Data())
            }
        } catch {
            reply((try? JSONEncoder().encode(WireReply(response: nil, error: error as? ServiceTransportError ?? .invalidMessage))) ?? Data())
        }
    }
}

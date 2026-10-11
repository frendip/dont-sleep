import XCTest
@testable import DontSleepIPC
import DontSleepCore

final class WireTests: XCTestCase {
    func testRejectsOversizedUnknownVersionAndReplay() throws {
        let gate = RequestGate()
        let request = ServiceRequest(command: .status, nonce: UUID(), sequence: 1)
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try gate.decode(data).command, .status)
        XCTAssertThrowsError(try gate.decode(data))
        XCTAssertThrowsError(try RequestGate().decode(Data(repeating: 0, count: 16385)))
        let incompatible = ServiceRequest(protocolVersion: 1, command: .status, nonce: UUID(), sequence: 1)
        XCTAssertThrowsError(try RequestGate().decode(JSONEncoder().encode(incompatible)))
    }
    func testConnectionCannotChangeNonceOrRegressSequence() throws {
        let gate = RequestGate()
        let nonce = UUID()
        _ = try gate.decode(JSONEncoder().encode(ServiceRequest(command: .status, nonce: nonce, sequence: 5)))
        XCTAssertThrowsError(try gate.decode(JSONEncoder().encode(ServiceRequest(command: .stop, nonce: UUID(), sequence: 6))))
        XCTAssertThrowsError(try gate.decode(JSONEncoder().encode(ServiceRequest(command: .stop, nonce: nonce, sequence: 4))))
        XCTAssertEqual(try gate.decode(JSONEncoder().encode(ServiceRequest(command: .stop, nonce: nonce, sequence: 6))).command, .stop)
    }
    func testExpiredEnvelopeCannotReachCommandHandler() throws {
        let encoded = try JSONEncoder().encode(ServiceRequest(command: .start(.permanent), nonce: UUID(), sequence: 1))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["expiresAt"] = 0
        XCTAssertThrowsError(try RequestGate().decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testEnvelopeWithoutEndToEndDeadlineIsRejected() throws {
        let encoded = try JSONEncoder().encode(ServiceRequest(command: .start(.permanent), nonce: UUID(), sequence: 1))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "expiresAt")
        XCTAssertThrowsError(try RequestGate().decode(JSONSerialization.data(withJSONObject: object)))
    }

    func testForwardedStartKeepsOriginalDeadlineAcrossBothServiceQueues() throws {
        let original = ServiceRequest(command: .start(.permanent), nonce: UUID(), sequence: 9, issuedAt: 100)
        let controllerRequest = try RequestGate().decode(JSONEncoder().encode(original), now: 105)
        let forwarded = controllerRequest.forwarded(nonce: UUID(), sequence: 1)
        let writerRequest = try RequestGate().decode(JSONEncoder().encode(forwarded), now: 109)
        XCTAssertEqual(writerRequest.command, .start(.permanent))
        XCTAssertNoThrow(try writerRequest.validateForExecution(at: 109))
        // Endpoint receipt was timely, but waiting on the writer queue must not extend the UI lease.
        XCTAssertThrowsError(try writerRequest.validateForExecution(at: 110)) { XCTAssertEqual($0 as? ServiceTransportError, .timedOut) }
        XCTAssertThrowsError(try RequestGate().decode(JSONEncoder().encode(forwarded), now: 111))
        // A lost UI reply followed by controller resumption cannot manufacture a fresh activation.
        XCTAssertThrowsError(try RequestGate().decode(JSONEncoder().encode(forwarded.forwarded(nonce: UUID(), sequence: 1)), now: 200))
    }
    func testDeadlineRejectsFutureRollbackOverflowAndExtendedBudget() throws {
        let request = ServiceRequest(command: .heartbeat(.init(sessionID: UUID(), generation: 1)), nonce: UUID(), sequence: 1, issuedAt: 100)
        XCTAssertThrowsError(try request.validateForExecution(at: 99))
        XCTAssertNoThrow(try request.validateForExecution(at: 100))
        XCTAssertNoThrow(try request.validateForExecution(at: 109))
        XCTAssertThrowsError(try request.validateForExecution(at: 110))
        let overflow = ServiceRequest(command: .start(.permanent), nonce: UUID(), sequence: 1, issuedAt: UInt64.max - 5)
        XCTAssertThrowsError(try overflow.validateForExecution(at: UInt64.max - 5))
        let extended = ServiceRequest(command: .start(.permanent), nonce: UUID(), sequence: 1, issuedAt: 100, expiresAt: 111)
        XCTAssertThrowsError(try extended.validateForExecution(at: 100))
    }

}

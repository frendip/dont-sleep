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
        let incompatible = ServiceRequest(protocolVersion: 2, command: .status, nonce: UUID(), sequence: 1)
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
}

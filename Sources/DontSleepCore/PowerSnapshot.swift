import Foundation

public enum PowerSource: String, Codable, Sendable { case ac, battery, unknown }

public struct PowerSnapshot: Codable, Equatable, Sendable {
    public let source: PowerSource
    public let percent: Int?
    public let sampledAt: UInt64

    public init(source: PowerSource, percent: Int?, sampledAt: UInt64) {
        self.source = source
        self.percent = percent
        self.sampledAt = sampledAt
    }

    public func blockingIssue(at now: UInt64) -> SessionIssue? {
        guard sampledAt <= now, now - sampledAt <= SessionEngine.powerFreshnessSeconds,
              percent.map({ (0...100).contains($0) }) ?? true else { return .powerUnavailable }
        switch source {
        case .unknown: return .powerUnavailable
        case .ac: return nil
        case .battery:
            guard let percent else { return .powerUnavailable }
            return percent <= 20 ? .lowBattery : nil
        }
    }
}

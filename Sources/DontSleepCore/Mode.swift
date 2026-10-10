import Foundation

public enum Mode: String, Codable, CaseIterable, Sendable {
    case permanent, fiveMinutes, fifteenMinutes, thirtyMinutes, oneHour, fourHours, eightHours

    public var durationSeconds: UInt64? {
        switch self {
        case .permanent: return nil
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .thirtyMinutes: return 1_800
        case .oneHour: return 3_600
        case .fourHours: return 14_400
        case .eightHours: return 28_800
        }
    }
}

import Foundation
import IOKit.ps
import Darwin

public enum NativePowerSource: String, Codable, Sendable { case ac, battery, unknown }
public struct NativePowerSample: Equatable, Sendable {
    public let source: NativePowerSource
    public let percent: Int?
    public let sampledAt: UInt64
    public init(source: NativePowerSource, percent: Int?, sampledAt: UInt64) { self.source = source; self.percent = percent; self.sampledAt = sampledAt }
    public static func decode(source: String?, current: Int?, maximum: Int?, at: UInt64) -> NativePowerSample {
        guard let current, let maximum, maximum > 0, current >= 0, current <= maximum,
              source == kIOPSACPowerValue || source == kIOPSBatteryPowerValue else { return NativePowerSample(source: .unknown, percent: nil, sampledAt: at) }
        let percent = Int((Double(current) / Double(maximum) * 100).rounded(.down))
        return NativePowerSample(source: source == kIOPSACPowerValue ? .ac : .battery, percent: percent, sampledAt: at)
    }
}

public enum PlatformClock {
    public static func now() -> UInt64 { nanoseconds() / 1_000_000_000 }
    static func nanoseconds() -> UInt64 {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return UInt64(Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom))
    }
    public static func bootID() throws -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1, size < 256 else { throw PlatformError.system("boot UUID", errno) }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { throw PlatformError.system("boot UUID", errno) }
        return String(cString: bytes)
    }
}

/// Synchronous bounded-size IOKit snapshot. Caller samples only while active or
/// in response to a UI request/power notification; this object owns no poller.
public final class NativePowerMonitor {
    public init() {}
    /// Retain the returned observation and service the main CFRunLoop.
    public func observeChanges(onChange: @escaping () -> Void) throws -> PowerObservation {
        try PowerObservation(onChange: onChange)
    }
    public func read() -> NativePowerSample {
        let now = PlatformClock.now()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return NativePowerSample(source: .unknown, percent: nil, sampledAt: now) }
        for source in sources {
            guard let dictionary = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  dictionary[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  dictionary[kIOPSIsPresentKey] as? Bool == true else { continue }
            return NativePowerSample.decode(source: dictionary[kIOPSPowerSourceStateKey] as? String,
                                            current: dictionary[kIOPSCurrentCapacityKey] as? Int,
                                            maximum: dictionary[kIOPSMaxCapacityKey] as? Int, at: now)
        }
        return NativePowerSample(source: .unknown, percent: nil, sampledAt: now)
    }
}

/// A passive IOKit power-event subscription; it owns no timer or worker thread.
public final class PowerObservation {
    private let callback: () -> Void
    private var source: CFRunLoopSource?
    fileprivate init(onChange: @escaping () -> Void) throws {
        self.callback = onChange
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<PowerObservation>.fromOpaque(context).takeUnretainedValue().callback()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        guard let source else { throw PlatformError.invalidPowerState }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
    deinit {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
    }
}

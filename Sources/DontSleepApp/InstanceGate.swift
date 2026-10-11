import Foundation
import Darwin

enum InstanceGate {
    static func existingPID(current: Int32, bundleID: String?, processes: [(Int32, String?)]) -> Int32? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return processes.first { $0.0 != current && $0.1 == bundleID }?.0
    }
}

final class InstanceLock {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }
    static func acquire(at url: URL) throws -> InstanceLock? {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno; close(fd)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return InstanceLock(descriptor: fd)
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

/// Wake the existing UI when Launch Services starts a separate copy instead of sending reopen.
enum ReopenRequest {
    static let name = Notification.Name("local.dontsleep.showControls")
    static func send(to pid: Int32) {
        DistributedNotificationCenter.default().postNotificationName(name, object: String(pid), userInfo: nil, deliverImmediately: true)
    }
}

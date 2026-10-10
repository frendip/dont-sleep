import Foundation

/// Keeps a responsive, explicitly active UI eligible to renew its service lease.
/// This activity deliberately permits idle system and display sleep.
final class ActivityLease {
    private let begin: (ProcessInfo.ActivityOptions) -> NSObjectProtocol
    private let end: (NSObjectProtocol) -> Void
    private var token: NSObjectProtocol?
    init(begin: @escaping (ProcessInfo.ActivityOptions) -> NSObjectProtocol = { ProcessInfo.processInfo.beginActivity(options: $0, reason: "Maintain user-requested service lease") }, end: @escaping (NSObjectProtocol) -> Void = { ProcessInfo.processInfo.endActivity($0) }) {
        self.begin = begin; self.end = end
    }
    func setActive(_ active: Bool) {
        if active {
            if token == nil { token = begin(.userInitiatedAllowingIdleSystemSleep) }
        } else if let token {
            self.token = nil; end(token)
        }
    }
    deinit { if let token { end(token) } }
}

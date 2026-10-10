import Foundation
import Darwin

public enum PowerCommand: Sendable { case readSettings, setDisabled(Bool) }
public enum ServiceCommand: Sendable { case restartWatchdog }
public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let output: Data
    public init(exitCode: Int32, output: Data) { self.exitCode = exitCode; self.output = output }
}
public protocol SystemCommandRunning {
    func run(_ command: PowerCommand, inheritingLockFD: Int32?) throws -> CommandResult
}

enum ChildObservation {
    case running, interrupted, exited(Int32), ownershipLost
}

/// Small OS boundary for deterministic delayed-reap tests. It does not expose
/// command execution or mutable child state to production callers.
protocol ProcessObservationDriver {
    func observe(_ pid: pid_t) -> ChildObservation
    func signal(_ pid: pid_t, _ signal: Int32)
    func nanoseconds() -> UInt64
    func pause()
}
private struct DarwinProcessObservation: ProcessObservationDriver {
    func observe(_ pid: pid_t) -> ChildObservation {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return .exited(status) }
        if result == 0 { return .running }
        return errno == EINTR ? .interrupted : .ownershipLost
    }
    func signal(_ pid: pid_t, _ signal: Int32) { kill(pid, signal) }
    func nanoseconds() -> UInt64 { PlatformClock.nanoseconds() }
    func pause() { usleep(10_000) }
}

/// Synchronous but bounded; invoke from the dedicated actuator queue, never UI.
/// Owns/reaps each child itself. No global SIGCHLD handler may reap its children.
public final class BoundedProcess: SystemCommandRunning {
    private let timeout: TimeInterval
    private let serialization = NSLock()
    private let observation: ProcessObservationDriver
    private enum ChildFence {
        case clear
        case pending(pid_t)
        case ownershipLost
    }
    private var childFence = ChildFence.clear
    public init(timeout: TimeInterval = 5) {
        self.timeout = max(0.01, min(timeout, 30)); self.observation = DarwinProcessObservation()
    }
    init(timeout: TimeInterval, observation: ProcessObservationDriver) {
        self.timeout = max(0.01, min(timeout, 30)); self.observation = observation
    }
    public func run(_ command: PowerCommand, inheritingLockFD: Int32? = nil) throws -> CommandResult {
        let arguments: [String]
        switch command {
        case .readSettings: arguments = ["-g"]
        case .setDisabled(let disabled):
            guard let fd = inheritingLockFD, fd >= 0, fcntl(fd, F_GETFD) >= 0 else { throw PlatformError.writerNotHeld }
            arguments = ["-a", "disablesleep", disabled ? "1" : "0"]
        }
        return try runProgram(path: "/usr/bin/pmset", arguments: arguments, inheritingLockFD: inheritingLockFD)
    }
    public func runService(_ command: ServiceCommand) throws -> CommandResult {
        switch command {
        case .restartWatchdog: return try runProgram(path: "/bin/launchctl", arguments: ["kickstart", "-k", "system/local.dontsleep.watchdog"], inheritingLockFD: nil)
        }
    }
    // Module-internal generic runner permits harmless process fixtures in tests;
    // external callers can invoke only the closed command enums above.
    func runProgram(path: String, arguments: [String], inheritingLockFD: Int32?) throws -> CommandResult {
        serialization.lock(); defer { serialization.unlock() }
        // A timed-out command is never accepted as successful later. Reaping
        // its retained child only permits this NEW command to proceed.
        switch childFence {
        case .clear: break
        case .ownershipLost: throw PlatformError.childNotReaped
        case .pending(let pid):
            switch observation.observe(pid) {
            case .exited: childFence = .clear
            case .running, .interrupted: throw PlatformError.childNotReaped
            case .ownershipLost:
                childFence = .ownershipLost
                throw PlatformError.childNotReaped
            }
        }
        var pipes: [Int32] = [0, 0]
        guard pipe(&pipes) == 0 else { throw PlatformError.system("pipe", errno) }
        defer { close(pipes[0]) }
        guard fcntl(pipes[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(pipes[1], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(pipes[0], F_SETFL, O_NONBLOCK) == 0 else {
            close(pipes[1]); throw PlatformError.system("pipe flags", errno)
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            close(pipes[1]); throw PlatformError.system("spawn init", errno)
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        var setup = posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO)
        setup |= posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO)
        setup |= posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        // Darwin's CLOEXEC_DEFAULT closes all descriptors unless explicitly
        // inherited via file actions. dup2 also clears close-on-exec on fd 198.
        if let fd = inheritingLockFD { setup |= posix_spawn_file_actions_adddup2(&actions, fd, 198) }
        setup |= posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        guard setup == 0 else { close(pipes[1]); throw PlatformError.system("spawn actions", setup) }
        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let environment: [String] = ["PATH=/usr/bin:/bin", "LC_ALL=C"]
        let env = environment.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnResult = argv.withUnsafeBufferPointer { argvPointer in
            env.withUnsafeBufferPointer { envPointer in
                posix_spawn(&pid, path, &actions, &attributes,
                            UnsafeMutablePointer(mutating: argvPointer.baseAddress!),
                            UnsafeMutablePointer(mutating: envPointer.baseAddress!))
            }
        }
        close(pipes[1])
        guard spawnResult == 0 else { throw PlatformError.system("posix_spawn", spawnResult) }
        let deadline = observation.nanoseconds() + UInt64(timeout * 1_000_000_000)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var failure: PlatformError?
        var killDeadline: UInt64?
        var finalDeadline: UInt64?
        while true {
            // Output is drained each iteration, bounded to avoid both pipe
            // deadlock and unbounded memory from a malfunctioning child.
            for _ in 0..<16 {
                let count = Darwin.read(pipes[0], &buffer, buffer.count)
                if count <= 0 { break }
                if output.count + count <= 65536 { output.append(contentsOf: buffer.prefix(count)) }
                else if failure == nil { failure = .system("output limit", EFBIG) }
            }
            let observed = observation.observe(pid)
            if case .exited(let status) = observed {
                // A child can write between the earlier drain and waitpid.
                // Its final bytes are now in the pipe; drain them after reap.
                while true {
                    let count = Darwin.read(pipes[0], &buffer, buffer.count)
                    if count <= 0 { break }
                    if output.count + count <= 65536 { output.append(contentsOf: buffer.prefix(count)) }
                    else { failure = failure ?? .system("output limit", EFBIG); break }
                }
                // Reap precedes every return, including timeout errors.
                if let failure { throw failure }
                let signal = status & 0x7f
                let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
                return CommandResult(exitCode: code, output: output)
            }
            if case .ownershipLost = observed {
                childFence = .ownershipLost; throw PlatformError.childNotReaped
            }
            let now = observation.nanoseconds()
            if now >= deadline && failure == nil { failure = .timedOut }
            if failure != nil && killDeadline == nil {
                // The child is ours and has not been reaped, so its PID cannot
                // be reused between this check and kill.
                observation.signal(pid, SIGTERM); killDeadline = now + 100_000_000
                finalDeadline = now + 2_100_000_000
            }
            if let when = killDeadline, now >= when { observation.signal(pid, SIGKILL) }
            if let when = finalDeadline, now >= when {
                childFence = .pending(pid); throw PlatformError.childNotReaped
            }
            observation.pause()
        }
    }
}

import Foundation
import Darwin
import DontSleepCore
import DontSleepPlatform
import DontSleepIPC

// Never initialize a real writer for an unprivileged invocation.
guard geteuid() == 0 else { fputs("Watchdog requires the installed root launchd job.\n", stderr); exit(77) }
let recoveryOnly = CommandLine.arguments == [CommandLine.arguments[0], "--recover-and-check"]
guard CommandLine.arguments.count == 1 || recoveryOnly else { exit(64) }
do {
    let writerLock = try WriterLock(directory: ServiceLocations.state)
    try writerLock.acquire()
    let journal = try RecoveryJournal(directory: ServiceLocations.state)
    let backend = PMSetSleepBackend(runner: BoundedProcess(timeout: 2), writerLock: writerLock)
    let runtime = try RecoveryRuntime(backend: backend, journal: journal, bootID: PlatformClock.bootID(), now: PlatformClock.now())
    if recoveryOnly { exit(runtime.response(now: PlatformClock.now()).snapshot.verifiedOff ? 0 : 1) }
    let power = NativePowerMonitor()
    let queue = DispatchQueue(label: "local.dontsleep.writer")
    func sample() -> PowerSnapshot {
        let value = power.read()
        return PowerSnapshot(source: PowerSource(rawValue: value.source.rawValue) ?? .unknown,
                             percent: value.percent, sampledAt: value.sampledAt)
    }
    var cachedPower = sample()
    let deadlineTimer = DispatchSource.makeTimerSource(queue: queue)
    let periodic = DispatchSource.makeTimerSource(queue: queue)
    var polling = false
    func scheduleDeadline() {
        if let deadline = runtime.nextDeadline {
            let now = PlatformClock.now()
            deadlineTimer.schedule(deadline: .now() + Double(deadline > now ? deadline - now : 0), leeway: .milliseconds(100))
            if runtime.response(now: now).snapshot.state == .active && !polling {
                periodic.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(100))
                polling = true
            } else if runtime.response(now: now).snapshot.state != .active {
                periodic.schedule(deadline: .distantFuture); polling = false
            }
        } else {
            deadlineTimer.schedule(deadline: .distantFuture)
            periodic.schedule(deadline: .distantFuture)
            polling = false
        }
    }
    func refresh() {
        cachedPower = sample()
        runtime.tick(now: PlatformClock.now(), power: cachedPower)
        scheduleDeadline()
    }
    deadlineTimer.setEventHandler { refresh() }
    deadlineTimer.schedule(deadline: .distantFuture); deadlineTimer.resume()
    periodic.schedule(deadline: .distantFuture)
    periodic.setEventHandler { refresh() }; periodic.resume()
    let observation = try power.observeChanges { queue.async { refresh() } }
    let listener = try AuthenticatedListener(service: ServiceLocations.watchdog, allowedPeer: .controller) { command, reply in
        let received = PlatformClock.now()
        queue.async {
            let now = PlatformClock.now()
            guard now >= received, now - received < 10 else { reply(.failure(ServiceTransportError.timedOut)); return }
            let idleHealth = command == .health && runtime.response(now: now).snapshot.verifiedOff
            if !idleHealth { cachedPower = sample() }
            _ = runtime.process(command, now: now, power: cachedPower)
            // A bounded system operation can consume time. Assess current safety
            // before publishing success or rescheduling a deadline.
            if !idleHealth { cachedPower = sample() }
            runtime.tick(now: PlatformClock.now(), power: cachedPower)
            scheduleDeadline()
            reply(.success(runtime.response(now: PlatformClock.now())))
        }
    }
    listener.resume()
    queue.async { scheduleDeadline() }
    withExtendedLifetime((writerLock, listener, periodic, deadlineTimer, observation)) { CFRunLoopRun() }
} catch {
    fputs("Watchdog refused startup: \(error)\n", stderr); exit(1)
}

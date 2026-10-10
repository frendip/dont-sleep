import Foundation
import Darwin
import DontSleepPlatform
import DontSleepIPC

// This same pinned binary has one fixed maintenance operation for the installer.
guard geteuid() == 0 else { fputs("Controller requires the installed root launchd job.\n", stderr); exit(77) }
let writer = XPCChannel(service: ServiceLocations.watchdog, peer: .watchdog)
if CommandLine.arguments == [CommandLine.arguments[0], "--stop-and-check"] {
    writer.send(.maintenance) { result in
        switch result {
        case .success(let response) where response.snapshot.verifiedOff: exit(0)
        default: fputs("Verified restoration could not be confirmed; services retained.\n", stderr); exit(1)
        }
    }
    dispatchMain()
}
guard CommandLine.arguments.count == 1 else { exit(64) }
do {
    let queue = DispatchQueue(label: "local.dontsleep.observer")
    var pending = false
    var failures = 0
    var lastRestart: UInt64 = 0
    var watching = false
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .distantFuture)
    func watch(_ enabled: Bool) {
        guard watching != enabled else { return }
        watching = enabled
        if enabled { timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(100)) }
        else { timer.schedule(deadline: .distantFuture) }
    }
    func observe(_ result: Result<ServiceResponse, Error>) {
        switch result {
        case .success(let response):
            failures = 0
            watch(!response.snapshot.verifiedOff)
        case .failure:
            watch(true)
            failures += 1
            let now = PlatformClock.now()
            if failures >= 2 && now >= lastRestart && now - lastRestart >= 30 {
                lastRestart = now
                // Exact launchd job identity, with a bounded process. The writer
                // lock fences any surviving child across this restart.
                _ = try? BoundedProcess().runService(.restartWatchdog)
            }
        }
    }
    func probe() {
        guard !pending else { return }
        pending = true
        writer.send(.health) { result in
            queue.async { pending = false; observe(result) }
        }
    }
    let listener = try AuthenticatedListener(service: ServiceLocations.controller, allowedPeer: .app) { command, reply in
        writer.send(command) { result in
            queue.async { observe(result) }
            reply(result)
        }
    }
    listener.resume()
    timer.setEventHandler { probe() }; timer.resume()
    // One startup observation detects an already-active writer after a broker
    // restart. A verified-OFF reply suspends all recurring observer work.
    queue.async { probe() }
    withExtendedLifetime((listener, timer)) { dispatchMain() }
} catch {
    fputs("Controller refused startup: \(error)\n", stderr); exit(1)
}

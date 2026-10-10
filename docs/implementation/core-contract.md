# Core contract

Core uses Foundation value types and performs no I/O. All times are UInt64 monotonic seconds within one boot, including sleep. The host supplies time and UUIDs; no random or calendar-clock dependencies exist in the reducer.

- `Mode: String, Codable, CaseIterable, Sendable`: `.permanent`, `.fiveMinutes`, `.fifteenMinutes`, `.thirtyMinutes`, `.oneHour`, `.fourHours`, `.eightHours`; `durationSeconds: UInt64?`.
- `PowerSource: String, Codable, Sendable`: `.ac`, `.battery`, `.unknown`.
- `PowerSnapshot: Codable, Equatable, Sendable`: `init(source: PowerSource, percent: Int?, sampledAt: UInt64)`; immutable properties of those names. Freshness allows at most five seconds. Battery requires percent 21...100. AC allows nil percent, but rejects an invalid numeric percent. Unknown/future/stale data blocks activation and stops an active operation.
- `SessionState: String, Codable, Sendable`: `.off`, `.enabling`, `.active`, `.restoring`, `.failed`, `.setupRequired`.
- `SessionIdentity: Codable, Equatable, Sendable`: `init(sessionID: UUID, generation: UInt64)`.
- `Session: Codable, Equatable, Sendable`: `init(identity: SessionIdentity, mode: Mode, deadline: UInt64?, leaseDeadline: UInt64)`.
- `SessionIssue: String, Codable, Sendable`: `.lowBattery`, `.powerUnavailable`, `.servicesUnavailable`, `.applyFailed`, `.restoreFailed`, `.leaseExpired`, `.timerExpired`.
- `SessionSnapshot: Codable, Equatable, Sendable`: state, selectedMode, session, power, issue, quitRequested, recoveryVerified; `verifiedOff: Bool` and `canEnable(at: UInt64) -> Bool`.
- `SessionEngine.init(servicesReady: Bool = true)`; public read-only `snapshot`; `mutating handle(_ event: Event, now: UInt64) -> [Effect]`.
- `SessionEngine.heartbeatIntervalSeconds = 5`, `leaseDurationSeconds = 30`, `powerFreshnessSeconds = 5`.

`Event: Equatable, Sendable` cases:

```
power(PowerSnapshot)
servicesReady(Bool)
recoveryChecked
enable(mode: Mode, sessionID: UUID)
disable
quit
heartbeat(SessionIdentity)
tick
applyResult(SessionIdentity, verified: Bool)
restoreResult(SessionIdentity, verified: Bool)
retryRestore
bootRecovery(SessionIdentity)
```

`Effect: Equatable, Sendable` cases:

```
apply(Session)
restore(SessionIdentity)
schedule(Session)
cancelSchedule
terminate
```

A first enable emits apply and starts an enabling session. Only a matching verified apply reply marks active and emits schedule. Repeated timer selection while active retains the session UUID, increases generation, resets the entire duration and lease, and emits schedule without reapplying the actuator. `selectedMode` survives normal off/on within this engine; a new engine defaults to permanent. The caller uses selectedMode when the toggle turns on.

Stop, quit, unsafe power, service failure, deadline and expired lease immediately enter restoring, revoke schedules, advance generation, and emit restore. The adapter must serialize actuator effects: revocation does not prove an older system child has stopped writing. It must wait for/reap or safely terminate the previous writer before restoration. Matching unverified restore replies enter failed. retryRestore advances generation and emits one new restore. Duplicate quit/disable do not duplicate restoration. Only proven absence of an unfinished own operation allows verifiedOff and an optional single terminate: matching verified restoration, or recoveryChecked after successful journal inspection found nil/restored record. Setup required may be verified off after this proof even if guard/trust readiness is unavailable. Initial servicesReady:false is unverified; readiness events alone cannot replace recoveryChecked. A pending quit waits through inspection and any needed restoration.

The host must deliver periodic tick/power samples while enabling or active. A heartbeat at/after lease expiry cannot rescue that session. Stale/future/backward samples cannot revalidate power. Event time is clamped monotonically, so clock rollback does not extend deadlines. A boot recovery always restores and never resumes; caller must obtain its identity from the protected journal. No active state can be constructed by remote Codable decoding into the engine.

Host obligations: start with `servicesReady: false` until trust checks and journal inspection complete, deliver `bootRecovery` for any unfinished record or `recoveryChecked` after finding nil/restored record, and set ready only after trust/guard checks succeed. `servicesReady(true)` alone does not establish journal proof. The constructor servicesReady:true is a compatibility shorthand for already-inspected, ready initialization; production starts false. SessionSnapshot has an optional recoveryVerified initializer parameter: absent means true only for explicit .off fixtures, false for .setupRequired. Its Codable recoveryVerified field carries the independent proof. Future-dated power samples are discarded on receipt and cannot become eligible merely as time advances; a new valid power event is required. Preserve the initial system snapshot and original journal baseline across every active-mode reselect; a new generation is a revocation/scheduling token, not permission to replace that baseline. `schedule` replaces the prior generation's wakeups and propagates the current lease to guards; matching heartbeats emit schedule even though the timer deadline stays unchanged. Tick evaluates current deadlines, so an old scheduler wakeup cannot stop a newer timer early. Retry restoration only after the preceding actuator operation has completed and been reaped. At generation exhaustion no retry can reuse a token; the adapter must keep activation blocked and diagnose the exhausted counter.

An unverified apply sets a sticky activation failure. After verified restoration it remains `.applyFailed` while own mode is confirmed off. Routine power/readiness/status refreshes and restoration failure/retry do not erase it. Unsafe power or unavailable services takes display precedence; safe readiness/power restores the activation failure message. Only a new accepted explicit enable clears the failure; an activation blocked by safety conditions does not. Consumers must show an activation-failure explanation even when `verifiedOff == true`; verifiedOff describes the absence of an unfinished own operation, not the success of the preceding request.

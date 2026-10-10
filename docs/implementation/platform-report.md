# Platform implementation report

Date: 2026-10-10.

Implemented files: `SleepBackend.swift`, `RecoveryJournal.swift`, `BoundedProcess.swift`, `NativePowerMonitor.swift`, `TrustPolicy.swift` in Sources/DontSleepPlatform. Tests: PlatformTests.swift and ProcessTests.swift in Tests/DontSleepPlatformTests. No Package.swift edits or commits by this owner.

Stable APIs are documented directly on the public types. Services consume SleepBackend, RecoveryRecord/RecoveryJournal, WriterLock, NativePowerMonitor, PlatformClock, TrustPolicy and BoundedProcess. Journal filename is recovery.json. NativePowerMonitor.observeChanges returns a retained PowerObservation; the daemon must service the main CFRunLoop. The observation is passive; active fallback polling belongs to service policy.

TDD evidence: initial compiling skeleton produced the expected validation/round-trip/authentication failures (12 tests, 24 assertions/failures including absent journal fixture fallout). Bounded process skeleton then failed its three timeout/output/lock tests. Implementations passed their respective checks. Additional interruption/schema/inheritance regressions bring platform coverage to 18 tests.

Latest verification: `xcrun swift test --scratch-path .scratch/platform-build` exited 0 at 10:02 UTC. At that snapshot, platform 18, Core 19, IPC 6, App 9 tests passed (52 total). A prior full run exposed four IPC fixture failures caused by /var being a symlink; the owner changed fixtures to /private/tmp, preserving the secure path policy, and the full run passed.

Read-only probes: local code-hash XPC accept/reject; inherited pmset lock remains held after parent close; production sleep snapshot + IOKit battery + boot UUID. Details and limitations are in platform-feasibility.md. No real power-write or root-service integration test was performed.

Security invariants for integration: only Watchdog holds lifetime writer lock; journal before mutation; no explicit lock release until every child is reaped; no activation from ambiguous baseline; no arbitrary command API; exact-version pins and UID on both XPC peers; never report success from command exit status alone; retained power observation with CFRunLoopRun; no passive state converted to verified OFF.


## Review corrections, 10:10 UTC

A reviewer found that an unreaped timeout permanently quarantined BoundedProcess even if the child exited later. Replaced the boolean with clear/pending-PID/ownership-lost states. Later calls perform one nonblocking observation of the retained child before any spawn. Only exact waitpid reaping clears the fence. ECHILD/unexpected ownership loss never leads to a new command or a potentially reused PID signal. A timed-out operation is never retrospectively reported successful.

Regression evidence: the old boolean failed `testUnreapedTimeoutRejectsNewCommandThenRecoversOnlyAfterReap`; after the fix all six ProcessTests passed. A deterministic observation/clock seam delays the observation of a harmless real `/usr/bin/true` child, then uses actual waitpid before releasing the fence. `testLostOwnershipNeverSignalsOrSpawnsAgain` protects the ECHILD boundary. The system safety reviewer inspected and accepted the fix.

Also added optional `RecoveryRecord.stopReason` (default nil), bounded to a 1–64 ASCII-letter token, to preserve SessionIssue raw values across UI crashes. Older version-1 journals without the key remain readable. Caller interprets only recognized issue tokens.

Full-suite snapshot after the child fix: Platform20, IPC11 and Core24 passed. App tests were concurrently in a red development phase (seven failing assertions across stop-queue/fresh-session/installer/single-instance cases); these were reported to their owner and are not claimed green here. Platform-only metadata tests were isolated with `--test-product DontSleepPlatformTests`; report their final run below.

Final platform-only verification at 10:11 UTC: `xcrun swift test --scratch-path .scratch/platform-build --test-product DontSleepPlatformTests` exited 0, all 22 tests passed (3 backend, 10 journal, 1 power, 6 process, 2 trust). No warnings in this product run.

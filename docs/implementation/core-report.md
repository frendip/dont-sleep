# Task 2 — Core implementation report

Implemented deterministic, I/O-free state reducer and Codable/Sendable value types in Sources/DontSleepCore. Contract is in core-contract.md. Package.swift was created with macOS 13/Core/test targets, then ownership returned to the orchestrator before other target additions. No root commands, sleep writes, service installations or commits were performed.

## Verified behavior

Nineteen SessionEngineTests cover the seven durations; battery 19/20 blocked and 21 allowed; AC20 allowed; missing/unknown/invalid/future/stale power; AC-to-low-battery immediate restore; charging recovery without auto-start; valid source changes preserving the timer; full timer reset on repeat selection; permanent cancellation; remembered mode on same-run toggle; exact 30-second lease boundary; stale generation heartbeat rejection; monotonic rollback; timer expiry without waiting for lease; duplicate quit; failed/retried restoration; wrong-generation callback rejection; stop while enabling and stale apply reply; unverified application; guard service loss; boot recovery without resumption; safe quit exactly once; explanatory issue on stale-power activation rejection.

Power freshness permits age <=5 seconds and blocks age >=6 integer seconds. Trusted AC source permits unavailable battery percentage because percentage does not constrain AC operation; invalid numeric values are rejected. All battery activation requires an actual valid percentage >20. The host must sample freshly before its periodic tick to avoid expiring the previous sample at coalescing boundaries.

## Red/green evidence

- 09:52 local: API established, battery-boundary test failed behaviorally with 2 assertions at battery21; minimal reducer then passed that test.
- 09:54: expanded 18-test suite failed with 51 expected assertion failures against the minimal reducer. A first run hit a test force-unwrap while boot recovery was absent; it was changed to an explicit missing-session assertion, then all tests ran red.
- 09:56: complete reducer passed 18 tests in a temporary package whose Source/Test directories symlink directly to the workspace. No copied source drift.
- 09:56: new stale-power rejection explanation test failed (nil issue versus powerUnavailable).
- 09:57: fix passed the complete isolated 19-test suite, 0 failures. Harness: /private/tmp/dont-sleep-core.EbZneW. Command: SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk swift test --package-path /private/tmp/dont-sleep-core.EbZneW.
- 09:57: full repository `swift test` rebuilt all targets and passed all 19 Core tests. Repository exit status was 1 due to parallel incomplete work, listed below.

## Full repository failures observed

At 09:55 an earlier filtered Core attempt was blocked at compile time by RecoveryIntegrationTests.swift:7 missing SleepBackend while the Platform owner was implementing that interface. That compile error was gone in the later full run.

The 09:57 full run showed signal 11 in DontSleepPlatformTests after JournalTests/testCorruptJournalDoesNotBecomeNoSession began, and signal 11 in DontSleepIPCTests after RecoveryIntegrationTests/testBootRecoveryRestoresAndDoesNotResume began. All six PresentationTests were red with 19 assertions while the UI implementation was in progress:

- testActiveTimerUsesServiceClockAndHoursWithoutClipping
- testLowBatteryBlocksControlsWithoutLosingVerifiedOff
- testNoTimerWhileOffOrPermanentAndStalePowerIsUnknown
- testQuitWaitsForVerifiedRestoreAndCoalescesDuplicateRequests
- testRestorationFailureHasErrorInsteadOfMisleadingOffSwitch
- testTransportFailureNeverRepresentsLastSnapshotAsCurrentOffOrOn

Build also reported XPCTransport.swift:38 weak-self ownership differs from the outer implicit strong capture. These are reported for integration; this report does not claim the whole repository passed.

## Integration boundaries

Effects do not enforce single-writer process ownership. The platform adapter must serialize apply/restore and terminate/reap an obsolete child before restoration. Generation checks protect reducer callbacks, not an already running OS write. The host owns continuous monotonic time within a boot and must run journal/trust recovery before publishing readiness. It must preserve the original baseline across mode/lease scheduling changes. Restoration failure remains visibly failed and cannot terminate the app; retries require explicit host retry events. No actual machine power behavior is claimed by these pure tests.

## Independent review fixes — 10:08 local

Read .scratch/reviews/core-review.md and verified both findings against the reducer before editing. Fixed P1 with an independent Codable SessionSnapshot.recoveryVerified flag. Initially unready startup cannot verify off, activate, or terminate. Event.recoveryChecked proves that successful journal inspection found no unfinished own operation; matching verified restoration also establishes proof. servicesReady(true) represents availability only and cannot substitute for inspection. Pending quit survives inspection, restoration failure and retry, then terminates once proven safe. Setup-required after verified restoration/clean inspection can still be verified off. Coordinated the new event with the Services owner for RecoveryRuntime's nil/restored-journal branch; no transport command was added. Constructor servicesReady:true remains an explicit compatibility shorthand for already-inspected ready state.

Fixed P2 by immediately discarding a future timestamp on receipt rather than keeping a sample that could become valid later. A fresh valid event is required to revalidate power.

Regression evidence:

- 10:04:59: uninspected startup test red with 5 assertions (premature proof/termination).
- 10:05:26: startup quit with failed/retried boot restoration red with 2 assertions (premature termination consumes the one-shot exit).
- 10:05:49: first P1 fix green, 21 Core tests.
- 10:06:17: future-sample/time-advance test red with 3 assertions, showing activation without a new sample.
- 10:06:30: future-sample fix green, 23 Core tests including clean-journal offline quit and refusal to override ongoing recovery.
- 10:07:12: explicit proof separation regression red with 5 assertions: readiness alone must not permit activation.
- 10:07:31: final scoped suite green, 24 Core tests, zero failures, same symlink harness.
- 10:07:53: full repository swift test: Platform18, IPC11, Core24 all pass. App14 runs with 3 failures in newly added BoundaryTests: testCapturedInstallerPreservesLiteralPathAndCannotExpandShellInput, testInstallerRejectsModifiedBytesBeforeProducingRootCommand, testSingleInstanceRejectsOtherMatchingAppButIgnoresSelfAndOtherProducts. PresentationTests6 now pass. Full-suite exit1; log /tmp/dont-sleep-core-review-full-test.log. These unrelated boundary tests were not modified here.

The Core source/API, regression tests and contract are ready for independent recheck. No commits or power changes performed.

## Activation failure visibility followup — 10:12 local

Read the system-safety-review baseline-conflict note: another actor's disabled setting must not be reset, and UI must explain why our requested activation failed. Previously an unverified apply followed by successful no-own-mutation restoration lost .applyFailed, appearing as silent OFF. Added an internal sticky activation-failure flag. Verified restoration, failed/retried restoration, and routine power/servicesReady/status refreshes preserve the failure. Low/unknown power and service unavailability take visible precedence while unsafe; the activation failure returns when conditions recover. A new accepted explicit activation clears it; a blocked activation attempt does not. No public API change.

Three regression tests first failed at 10:11:44 with four assertions, then all 27 Core tests passed at 10:12:01. Tests protect persistence after restoration/status refreshes, precedence plus blocked activation, and persistence through restore failure/retry. Native UI owner was notified to display a generic activation failure banner for .applyFailed even when state off and verifiedOff true.

Full repository `swift test` immediately afterward exited 0: Platform22, IPC11, Core27, App16 = 76 tests, zero failures. Captured log: /tmp/dont-sleep-core-sticky-full-test.log. No compiler warnings were present in this incremental run. This supersedes the previous in-progress shared-suite failures for these sources. No power mutation, installation or commits performed. Scoped delta ready for independent recheck.

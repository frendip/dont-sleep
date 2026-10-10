# UI and integration review — 2026-10-10

Final re-review of Sources/DontSleepApp/** and Tests/DontSleepAppTests/** after the NativeUI fixes, frozen at 10:31 Moscow time. Supporting IPC/runtime code was read to trace real errors and lease behavior. Inputs: spec v1.3, approved design B concept, existing apple-design report, and native light/dark PNGs.

No installation, service registration, or power changes were performed. This reviewer changed only this scratch report and ran focused existing regression tests.

## Spec verdict

Accepted for the reviewed source scope. No remaining P1/P2 UI or integration finding was established after the fixes. The implementation now follows launch-off/recover-first, serialized commands, safe quit, first-run/repair distinctions, visible-menu countdown, idle event waiting, and low-battery notification requirements.

This is not acceptance of installed hardware behavior under spec 7.2 or the energy budgets under 7.4. Those checks remain pending.

## Quality verdict

Accepted for the reviewed source scope. The main-actor lease task, explicit session ownership, retained stop/quit intent, separate display ticker, authoritative instance flock, and bounded activity token provide coherent lifecycle boundaries. Focused regression evidence covers the important command interleaving and heartbeat starvation cases.

Independent verification at 10:31:59: four focused tests passed with zero failures, using:
    /usr/bin/swift test --skip-build --scratch-path .scratch/ui-build --filter 'ActivityLeaseTests|testActivityEndsBeforeStopRequestAndDoesNotDuplicateAcrossStatusRefresh|testFrequentStatusRefreshesCannotPostponeOwnedSessionHeartbeat|testExplicitStopQueuesBehindInFlightStatus'

The NativeUI implementation report records the final full app-scoped run: 22 tests, zero failures, 10:31:05.095. The reviewer did not repeat the full suite. The parent’s final full Swift run was also inspected in .scratch/final-swift-tests.log: 83 tests total (Core 27, Platform 22, IPC 12, App 22), zero failures, finishing at 10:32:20.371.

## Findings closed during review

- **[P1, closed] Fresh UI resumed the previous crashed UI session.** Initial status previously adopted active state and renewed its lease automatically. AppModel.swift:170 now treats a non-owned session as recovery; AppModel.swift:92 and :183 require explicit ownership for renewal/activity. A fresh launch defaults its preferred mode to permanent and cannot revive the prior timer. AppModelTests.swift:58 exercises orphan-session recovery.

- **[P1, closed] OFF was discarded during a background RPC.** The prior inFlight guard lost the action while the switch stayed enabled. AppModel.swift:122 now records OFF intent, immediately ends the activity, serializes stop after the current RPC, and AppModel.swift:130 revokes ownership until verified recovery. The lost-reply case therefore cannot reconnect and resume renewal. AppModelTests.swift:67 and :85 cover queued OFF and lost stop reply.

- **[P1, closed] Real first-launch trust errors hid setup.** Missing protected trust paths throw a platform error before XPC, rather than the transport error previously expected. AppModel.swift:152 checks positive installation absence independently of error type. AppModel.swift:47 and MenuPanel.swift:47 separately expose repair whenever disconnected. A retained installation, rebuild pin mismatch, or raw NSError keeps the unknown-state title and cannot use the never-installed quit exception.

- **[P2, closed] Quit could remain stuck after canceled setup.** A quit requested during installation previously bypassed the absence exception permanently. AppModel.swift:162 rechecks a pending quit after RPC/installer completion and terminates once only when the installation is positively absent. AppModelTests.swift:99 covers reverified absence; uncertain installed state remains blocked.

- **[P2, closed] Background ticking/polling and awaited-RPC freshness.** AppModel.swift:65 owns a separate visible-menu display ticker, so delayed IPC does not freeze charge-age or the countdown. AppModel.swift:80 stops monitoring when verified OFF and the menu is closed. Native power events provide passive refresh, with coalescing behind the serialized RPC.

- **[P2, closed] Frequent status events postponed heartbeat indefinitely.** Recreating a fixed five-second task after every refresh reset the schedule. AppModel.swift:80 retains the task when its role is unchanged, schedules active renewal from lastHeartbeatAt, and advances that time only inside an accepted heartbeat call. The independent repeated-refresh regression ran for 6.19 seconds and observed a heartbeat despite 200 ms status refreshes.

- **[P2, closed] Start/retime controls advertised availability during serialization.** AppModel.swift:50 sets a mode-only in-flight flag; Presentation.swift:50 excludes it from allowsModes. An active OFF switch and quit remain available. The strengthened queued-OFF test checks both properties before sending OFF.

- **[P2, closed] System low-battery notices were absent.** AppModel.swift:184 now emits on the issue transition; the notification adapter checks macOS permission, and in-menu protection remains independent. Unconfirmed restoration receives additional wording. Permission is requested through explicit setup.

- **[P2, closed] Instance check had a race.** DontSleepApp.swift:32 now uses a lifetime nonblocking flock as the sole authority. The post-lock process-list rejection was removed, so a winner cannot exit merely because a losing instance is still listed.

- **[P2, closed] Hidden-menu App Nap could throttle a healthy lease task.** ActivityLease.swift:14 uses only userInitiatedAllowingIdleSystemSleep. The exact flags exclude idle-system-sleep disable, display-sleep disable and latencyCritical. AppModel.swift:183 holds it only for a connected, explicitly owned active session; OFF/quit intent and transport failure end it immediately. It neither sends heartbeats nor replaces watchdog enforcement. Independent tests verified one begin/end lifetime and end-before-stop ordering.

Restoration failure and disconnected titles are preserved: recovery gating no longer overrides them with an assumed restoration status. Older service timestamps cannot overwrite newer accepted state. Command-Q and applicationShouldTerminate both reach the same quit gate; termination follows verifiedOff, except for positively proven never-installed state.

## Design and accessibility review

The quiet, status-first design B thesis is retained. Inspected native PNGs include active timer, permanent, OFF, low battery, restoration error, setup, unknown/repair, and 100% AC with eight hours. The 340 pt panel, 16 pt padding, 30 pt mode rows, persistent Заряд, inline time, seven choices, and separate quit action match the approved hierarchy. No clipping was observed in 100% plus 8:00:00 or the error/setup text.

Warnings use shape and text in addition to color. Error states replace the switch, mode items expose selected values, and the menu mark now has an explicit accessibility element/label rather than inheriting a hidden decorative view. Semantic text/background colors support light and dark appearance; the opaque panel has no transparency dependency. The initial preview-host inactive gray ON switch is a rendering limitation, not evidence that the product control is disabled.

Apple-design references read: accessibility.md (Vision: “Convey information with more than color alone”), layout.md, typography.md, color.md, designing-for-macos.md, menus.md, keyboards.md, notifications.md. No separate visual P1/P2 was established.

## Required live validation still pending

- Signed installed launch, administrator denial/retry, retained-install repair and actual Command-Q/native termination.
- Real keyboard traversal and VoiceOver accessibility tree, increased-contrast appearance, and menu-bar badge legibility.
- Low-battery system notification delivery/denial and restoration wording on actual service transitions.
- Hidden-menu App Nap/lease timing, including a hung main thread; user preferences may override activity hints.
- CPU, wakeups and energy measurements with OFF and active sessions.
- Crash, reboot, closed-lid and physical power-transition acceptance.

These are limits of source/tests/PNG review, not passed hardware checks.

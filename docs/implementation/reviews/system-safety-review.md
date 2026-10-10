# System safety review — Don’t Sleep

Review date: 2026-10-10. Baseline `1d802f3`; implementation is mostly untracked and was inspected directly. This is an independent source review with harmless probes only. No helper installation, root power write, reboot, or closed-lid trial was performed. Product owners applied the reported fixes during review; final source was re-inspected. Fresh final build/install-validation evidence remains the parent/owners’ responsibility.

## Security/correctness verdict

**No remaining P0/P1 source blocker found in this scope after fixes.** The architecture has meaningful safety boundaries: exact code hashes and UID checks on both XPC directions, an allowlisted message protocol, one serialized actuator, an inherited writer lock, durable prepared journal before mutation, readback after writes, and no restoration claim on failed recovery. The installer identity, child-reaping, and startup-retry P1 findings are now closed in source. No P0 found. Final signed-bundle validation and installed/hardware tests remain separate gates.

### P1 — Root bootstrap and new payload were not tied to running app identity — FIXED

Original locations: `Sources/DontSleepApp/AppModel.swift:116-119`, original `scripts/install-helpers.sh:39-55` (files are being edited).

Reproduction: launch the legitimate app, choose setup, leave the administrator dialog pending, and replace its user-writable `Contents/Resources/install-helpers.sh`. The authorized command was `/bin/bash <mutable script path>`; after approval it read and executed the replacement as root. Independently, replacing the source app/helpers with attacker-created ad-hoc code using the expected identifiers passed the installer's original checks because it pinned whichever hashes it had just copied. Protected copying alone does not bind payload to the trusted running application.

Threat boundary: a local process with the installed user's file access, but without root, racing legitimate administrator approval. This is not remote execution, and does not claim protection from an administrator deliberately authorizing arbitrary malicious software. Exact cdhash pins correctly constrain later XPC peers; the vulnerability was first installation/update authorization.

Required bounded fix (owners implementing): compile a SHA-256 digest of the installer into the app; read/capture the installer once, verify that digest, and pass the captured literal bytes to the authorized shell instead of a path. Read the running app's dynamic SecCode identity; require that exact cdhash on the root-protected copied full bundle. Strictly verify the entire copied bundle, then derive helper executables only from that protected verified copy. Verify the resource hash against the compiled constant in the final built app. Harmless mismatch/signature fixtures suffice for this stage; do not run the installer as root just to test it.

Closure: independently verified `InstallerProgram.pinnedSHA256` exactly matches `shasum -a 256 scripts/install-helpers.sh` (`3c69528560b579fb7f7598a71eb6862a6f2900a0911a2d693848f5d58e46e240`). Captured bytes are safely shell-quoted into `bash -c`, with `/usr/bin/env -i`, a fixed PATH, and `--noprofile --norc`. Protected full bundle signature and expected outer cdhash are checked before copying helpers. SDK `SecCode.h:333-339` warns that signing information on a dynamic SecCode includes data from disk; the final UI code therefore constructs an exact requirement from the captured hash and checks it against the live SecCode with `SecCodeCheckValidity` before authorizing that hash. This closes the source-level authorization gap. A fresh signed-bundle preparation check is still required to verify the final packaged resource and Security call at runtime.

### P1 — Unreaped child permanently disables all future recovery attempts — FIXED

Original locations: `Sources/DontSleepPlatform/BoundedProcess.swift:110-123`, `Sources/DontSleepController/main.swift:37`.

Reproduction through a deterministic process fixture: a pmset child changes the setting, times out, and is not reaped within the extra 2.1-second observation budget. The runner sets `quarantined = true` and drops its PID. Even if the child later exits, every subsequent read/write fails at the boolean guard. The watchdog remains responsive, so Controller counts its failed-state replies as healthy and never restarts it. The new automatic recovery timer therefore cannot recover from a transient OS delay; the persisted disable can remain indefinitely until external intervention.

Required fix (platform owner implementing): retain the owned unreaped PID, perform one bounded nonblocking reap check before subsequent attempts, refuse all commands while it is still alive, and clear quarantine only after that exact owned child is confirmed reaped. Unexpected wait errors must fail closed without signaling a possibly reused PID. A command that originally timed out must never later be treated as successful. The existing lifetime/inherited flock must stay held throughout.

Closure: inspected the new `ChildFence` implementation and two deterministic delayed-observation regression tests. The platform owner reports all six ProcessTests passing, including actual harmless-child waitpid confirmation; this reviewer did not rerun that suite. Pending children block new commands; confirmed reaping permits only the next command; lost ownership stays fail-closed.

### P1 — Failed boot recovery retry timer initially remains disarmed — FIXED

Location reviewed: `Sources/DontSleepWatchdog/main.swift:48-70`.

After failed boot recovery, `runtime.nextDeadline` contains a retry deadline, but both dispatch timers initially remain at distantFuture until an XPC request or power event calls `scheduleDeadline()`. If Controller is unavailable and no power notification occurs, recovery does not retry autonomously. Call `scheduleDeadline()` after resuming timers during startup and pass the actual continuous timestamp when constructing RecoveryRuntime. Closure: current Watchdog main passes `PlatformClock.now()` at line 16 and queues `scheduleDeadline()` at line 72 before entering the run loop. This closes dependence on external Controller/UI/power traffic.

## Spec compliance verdict

**The reviewed safety architecture and two identified service/install P2 gaps are addressed in source.** This is not a verdict on the full UI specification or completion of hardware/energy acceptance. Two P2 gaps were identified and closed as follows:

- FIXED: Controller main originally scheduled five-second health requests continuously, including verified OFF (`Sources/DontSleepController/main.swift:28-33`). This violates §7.4's requirement to stop periodic service confirmations after recovery. Suspend the observer while verified OFF and restart it on start/recovery/error, with an immediate authenticated health check before accepting a new session. Current Controller main lines 27–37 now suspend the timer on verified OFF, with an initial probe and observation of forwarded requests. UI idle polling is being handled by the separate UI review.
- FIXED with a bounded repair path: Installer originally published `bin` and `trust.json` separately and lost its old code pair on cleanup, so an interrupted update could not repair itself. Current installer lines 101–128 verify the previous protected binary/trust pair, copy it to protected staging, verify the copy, and restore it only when both fixed jobs are unloaded. Lines 158–176 preserve the previous pair across publication; subsequent offline recovery still acquires the writer lock. The mkdir-based stale setup lock was replaced with supported descriptor-mode `lockf`; lock remains held through the shell-owned FD and releases when it closes. This reviewer checked source/shell syntax and lockf's documented FD invocation; the service owner separately reported a harmless contention/release fixture. Repair after a reboot that has already loaded mismatched jobs still intentionally requires those jobs to be unloaded first. Root installation, crash-at-each-publication-step, and reboot repair have not been executed and must not be described as validated.

## Scope and checks

Read: approved design, feasibility and service contract; all Platform/IPC sources; Controller/Watchdog mains; installer/uninstaller; launchd resources; recovery/process tests; relevant UI installer code. No privileged commands were executed. `bash -n scripts/install-helpers.sh scripts/uninstall-helpers.sh` passed. Existing test source covers journal-before-mutation, unfinished-phase recovery, lease/controller loss, low battery, repeat stop, bounded ordinary timeout, lock inheritance, and verification failures. Those tests do not substitute for installed Mach-service adversarial peers, real pmset mutation/recovery, power-loss durability, launchd child-group behavior, reboot, or energy measurements.

No finding is made merely because a restored/no-own-session journal does not clear an external actor's sleep-disable setting: the specification explicitly forbids resetting external settings on boot. The UI must still describe its own mode accurately and explain baseline conflicts.

## Handoff conditions

1. DONE in source: bootstrap/payload TOCTOU closed, final source script digest matches compiled constant.
2. DONE in source/tests: quarantined-child recovery progresses after confirmed reap, preserving fencing.
3. DONE in source: failed boot-recovery retry is armed independently of Controller/UI traffic.
4. DONE in source: Controller idle polling stops at verified OFF, and interrupted-update repair preserves a verified previous pair.
5. Before calling the packaged app ready, run the final build and harmless signed-bundle installer-preparation check after the last source/resource edits. Finish the separate UI review. Do not claim installed-service, actual power mutation/recovery, reboot, or energy validation from this review.

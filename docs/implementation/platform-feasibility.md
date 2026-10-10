# Platform feasibility and trust decision

Date: 2026-10-10. Scope: target Mac only; implementation and nonprivileged probes. This report does not claim that root services have been installed or tested through reboot.

## Local toolchain

- macOS 26.7.1, build 25G241, Apple Silicon.
- Xcode 27.0; Swift 6.4 (swiftlang-6.4.0.34.1).
- `security find-identity -v -p codesigning`: zero valid identities, confirmed outside the read-only sandbox.
- Compilation works. Direct absolute-path swiftc invocation needs an explicit SDK; `xcrun swift` resolves it.
- Ad-hoc hardened-runtime signing works without an Apple developer account.

## Installation decision

Use administrator-authorized local installation of legacy launchd system jobs, with root-owned executables, configuration and a version-pinned trust manifest. Do not claim reliable SMAppService daemon installation for the available ad-hoc identity.

The installed ServiceManagement SDK header documents notarization for apps containing LaunchDaemons, and preserves legacy jobs installed under `/Library/LaunchDaemons`. Apple DTS warns that ad-hoc SMAppService signing causes persistence problems; see [DTS guidance](https://developer.apple.com/forums/thread/799910). Apple’s [SMAppService walkthrough](https://developer.apple.com/forums/thread/802443) uses a selected signing team. No account or certificate was created here.

Deployment paths agreed with the service implementation:

- `/Library/Application Support/DontSleep/trust.json`: root-owned, readable, no group/other write.
- `/Library/Application Support/DontSleep/state`: root-owned mode 0700.
- `state/recovery.json`: mode 0600, root-only durable journal.
- `state/writer.lock`: mode 0600, persistent inode, never delete while services can run.
- Fixed launchd labels: `local.dontsleep.controller`, `local.dontsleep.watchdog`.

Installer must stage protected copies before verification, refuse unsafe paths, preserve unresolved journals, recover before update/uninstall, and publish code/pins together. Installation and real reboot validation remain a separate administrator-authorized gate. Build scripts must not register jobs or change power settings.

## XPC identity

`TrustManifest` version 1 stores authorizedUID and three `TrustedCode` entries (`app`, `controller`, `watchdog`), each containing `identifier` and a 40-digit `cdhash`. Exact signed-code hashes include the signed executable identity and metadata; see [Apple code-hash documentation](https://developer.apple.com/documentation/technotes/tn3126-inside-code-signing-hashes) and [requirement syntax](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html).

Both public Foundation gates are used: `NSXPCListener.setConnectionCodeSigningRequirement` rejects new untrusted peers, and `NSXPCConnection.setCodeSigningRequirement` checks messages. UID is independently required: installed user for UI, root for services. Bundle ID alone, PID alone, arbitrary self-signed identities, and broad “any ad-hoc code” requirements are never accepted.

Probe result: a hardened-runtime ad-hoc executable with an exact cdhash requirement accepted an anonymous XPC connection to the expected code; an all-zero hash was rejected with NSCocoaErrorDomain 4097. This proves local requirement enforcement, not installation or all cross-process attack cases. Temporary source: `/var/folders/9g/btqsnq456z963ksh_381k0ww0000gn/T/dont-sleep-xpc-probe-mwpajzix/main.swift`.

## Snapshot and mutation boundary

The backend reads actual `SleepDisabled` from IOPMrootDomain with public IOKit registry APIs. It reads the persisted system setting from bounded `/usr/bin/pmset -g`, whose system-wide section is produced from stored system power settings. [Apple pmset source](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m) provides context; target-host probes are the compatibility evidence.

On this Mac, the raw preference is `/Library/Preferences/com.apple.PowerManagement.plist`, `SystemPowerSettings.SleepDisabled=false`. Production reads do not parse or write that plist directly. The current production read probe returned actual=false, persisted=false, battery=83%, and a boot UUID.

Baseline must contain explicit, unambiguous false for both actual and persisted values. True, missing, malformed, duplicated, or unsupported values block activation. An absent persisted key is not silently converted to false: the narrow pmset interface cannot restore key absence exactly.

Only fixed commands are exposed: `pmset -g`, `pmset -a disablesleep 1/0`, and Controller’s fixed watchdog restart. There is no shell or arbitrary executable/path in the production command interface. Exit zero is insufficient: apply/restore verify actual and persisted state.

## Single writer and inherited-lock probe

Recovery/Watchdog is the sole power writer. Controller is a separate broker and health observer. Watchdog acquires the root-private lock for its lifetime before reading/recovering the journal. Every power child inherits that same open-file description as descriptor 198 through explicit posix_spawn dup2 actions. All other descriptors close by default. Lock acquisition is nonblocking.

Read-only probe on the installed pmset:

1. Parent acquired an exclusive flock on a temporary file.
2. Spawned `/usr/bin/pmset -g assertionslog` with the lock duplicated to fd 198.
3. `lsof` confirmed fd 198 referred to that file.
4. Parent closed its copy; a second open still could not acquire the lock.
5. After pmset terminated and was reaped, the second open acquired it.

The production runner’s descriptor inheritance also has an automated harmless-child regression test. The live probe proves the installed binary preserves the descriptor on its assertions-log read path. It does not directly execute the power-writing path or prove behavior on future OS updates. Those remain target-specific validation boundaries.

Do not call `WriterLock.release()` while a power child may live: flock unlock applies to the shared open-file description. Deinitialization intentionally only closes the parent descriptor. After an owner crash, a replacement writer must fail closed while the child still owns the lock. launchd group cleanup and kickstart success alone do not prove recovery.

## Process and storage failure behavior

BoundedProcess owns waitpid for each immediate child and does not use a global SIGCHLD reaper. Timeout sends TERM, then KILL, with bounded reap observation. Reaped timeout throws; unconfirmed termination retains the owned child PID and prevents subsequent commands. Each later call performs a nonblocking waitpid for that exact child; only confirmed reaping clears the block for a new command. The original timed-out command never becomes successful retroactively. Unknown ownership (including ECHILD) remains permanently blocked without further PID signalling. Children remain in the launchd job’s process group. Output is bounded; environment is fixed.

Protected-directory operations use openat with O_NOFOLLOW through path components, owner/mode checks, regular-file and single-link checks. Journal replacement writes a unique temporary file, fsyncs, requests F_FULLFSYNC, renames within the held directory, and fsyncs the directory. Corrupt/future-schema records never become “no session.” Snapshot identity cannot be replaced during unfinished recovery.

The journal tests cover stale interrupted temporary artifacts and atomic replacement behavior. They do not yet inject a real process crash at every durability syscall or a power-loss event.

## Remaining gates

- Real root installation and Mach service connections with adversarial clients.
- Actual writer hang/crash plus replacement startup while inherited lock remains held.
- Real power-write readback, failure recovery, restart/reboot, update/uninstall.
- Complete AC/battery/lid trials and threshold transition for the integrated app.
- Runtime/energy measurements and independent security review.

No root service, pmset write, credential creation, or system setting mutation was performed by this platform task.

# Task 2 independent Core review

## Latest scoped delta: activation failure visibility

**Spec compliance: pass. Code quality: pass.** No actionable finding in the sticky `.applyFailed` change. Reviewed the current reducer, the contract's added failure-visibility paragraph, the implementation report's followup, and all three new regressions. This delta addresses design section 4.2's requirement to explain an activation conflict without changing another actor's settings.

The private `activationFailurePending` flag is set only by a matching unverified apply reply, survives restoration failure/retry and verified restoration, and is cleared only after a new explicit enable passes every acceptance guard. `idleIssue` preserves the message across power/readiness/inspection refreshes while allowing unsafe power and unavailable services to take temporary visible precedence. The change does not alter verified-off proof or callback identity checks.

A fresh targeted Swift harness over the unchanged current Core sources exited 0 with three assertion groups passing:

- Verified restoration leaves `verifiedOff == true` together with `.applyFailed`; routine power/readiness/tick and recoveryChecked events preserve the explanation; an accepted explicit start clears it.
- Battery20, unknown power, and unavailable services temporarily take precedence; blocked start attempts do not erase the underlying failure; safe power plus readiness restores `.applyFailed`.
- Failed restoration and retry preserve the activation failure; the old generation's successful restore reply cannot clear the outstanding operation; current verified restoration restores the message.

The author reports Core27 and full76 passing. No existing suite was repeated for this delta. No product/test edits or system-power commands were made. The earlier final recheck and resolved findings below remain valid.

## Final recheck verdicts

- **Spec compliance: pass for Task 2 scope.** Both reported safety defects are resolved. Journal inspection is represented independently of service availability; pending quit waits for proof or verified restoration. Future power input is discarded and cannot become eligible as time advances.
- **Code quality: pass for Task 2 scope.** The changes preserve the reducer's deterministic, I/O-free design and its callback-generation guards. No remaining actionable finding was identified in this scoped recheck.

Rechecked current Core source, the updated contract/report, the five added regression tests, and the `RecoveryRuntime` journal-loading integration. `RecoveryRuntime.swift:18-21` delivers `recoveryChecked` only after successful load returns nil/restored, or starts `bootRecovery` for an unfinished record. A thrown journal load does not create proof. Production still initializes `SessionEngine(servicesReady: false)`; the documented true constructor remains an explicit shorthand for an already-inspected initialization. `.servicesReady(true)` on an initially unready engine does not substitute for inspection.

Independent fresh verification used the current four Core source files in a temporary Swift assertion harness. It exited 0 with all six groups passing:

1. Original P1 sequence: initial unready state is not verified off; quit waits; service readiness and power cannot supply proof; clean inspection emits exactly one terminate.
2. Activation remains blocked after readiness alone; clean inspection permits it; inspection cannot override an outstanding operation.
3. Pending quit survives boot recovery failure, an attempted inspection event while failed, retry, and a stale successful restore reply; only matching verified restoration emits terminate.
4. Clean journal proof permits safe quit with services still unavailable.
5. Original P2 sequence: future input is discarded; advancing time cannot enable; a new valid sample restores eligibility.
6. Future input during active operation immediately starts restoration with powerUnavailable.

The author reports 24 passing Core tests. This review did not rerun the existing suite or the full repository suite; the fresh targeted assertion harness verifies the changed boundaries without product/test edits or system-power commands. Existing host obligations remain: authentic main-thread UI heartbeats, continuous boot time, protected journal inspection, serialized/reaped actuator operations, retained original baseline, and periodic safety delivery. Passing this Core review does not certify those separate implementations or hardware behavior.

---


Reviewed the captured `.scratch/reviews/core.diff`, all four current Core source files, the Core contract/report, Task 2 plan, and the relevant design requirements. This review does not treat unfinished UI, transport, or platform work as Task 2 defects.

## Initial verdicts — superseded by the successful recheck

- **Spec compliance: changes required.** The nominal Task 2 behavior is present, including strict battery >20%, all seven durations, timer reset, lease expiry, monotonic event time, guarded callback identities, verified restoration, and recovery without resumption. Two safety boundaries below do not satisfy the specification/contract.
- **Code quality: changes required.** The reducer is small, deterministic, and performs no I/O. Matching callbacks and the centralized restoration path are clear. However, its public verification predicate overstates startup certainty, and invalid future power input remains eligible for later activation. These are state-model defects rather than missing UI or transport implementation.

## Original findings — both resolved

### [P1] Do not mark uninspected startup state as verified off

**Location:** `Sources/DontSleepCore/SessionState.swift:51` (with `SessionEngine.swift:34-36` and `171-174`).

`verifiedOff` returns true for every sessionless `.setupRequired` snapshot. A new `SessionEngine(servicesReady: false)` therefore reports verified off before the host has checked the protected journal or supplied any readiness proof. Calling `.quit` at this point emits `.terminate` immediately. An unfinished prior operation can still exist; the engine has simply not received `bootRecovery` yet. A consumer using the documented `verifiedOff` contract can consequently show confirmed off or finish ordinary quit while recovery is still unknown.

**Reproduced sequence:** initialize with `servicesReady: false`; inspect `snapshot.verifiedOff` => `true`; handle `.quit` at t=0 => `[.terminate]`. No readiness, recovery, or verified restore event occurred.

The host obligation to inspect the journal before publishing ready/off does not make the Core predicate truthful: the explicit not-ready initialization is already exported as verified off, and Core itself authorizes termination. Preserve an independent proof that journal inspection found no unfinished operation, or that restoration was verified, and require that proof for `verifiedOff`/termination. A setup-required state after a genuinely verified restore can still be verified off.

This violates design sections 2.1, 2.3, and 5: startup recovery precedes confirmation, uncertain state must not be called off, and quit must await restoration proof.

### [P2] Reject future power samples permanently rather than letting time validate them

**Location:** `Sources/DontSleepCore/SessionEngine.swift:51` (validation in `PowerSnapshot.swift:17`).

The reducer stores a sample even when its `sampledAt` is in the future. `blockingIssue` checks the timestamp against the current time only, so this previously rejected sample becomes valid when the clock reaches its timestamp. Activation can then use it without receiving any new trustworthy power reading. This contradicts the contract that future samples cannot revalidate power, and the design requirement to remain blocked until trustworthy power data arrives.

**Reproduced sequence:** on a fresh ready engine, deliver AC/80% with `sampledAt=2` at t=0; activation is initially blocked. Deliver no further power event. At t=2, handle `.enable(.permanent, ...)` => state `.enabling` and an `.apply` effect. The sample never represented a validated reading at receipt time.

Invalidate or discard a future sample on receipt and keep power unavailable until a new valid sample arrives. Add a regression exercising time advancing after a future sample; the current test only checks rejection at its initial receipt time.

## Evidence and boundaries

A temporary Swift interpreter harness concatenated the unchanged four Core source files and executed both sequences. Exit status was 0; output was:

```text
F1 unready verifiedOff: true
F1 unready quit effects: [main.Effect.terminate]
F2 initially future sample blocked: true
F2 no newer power, state: enabling effects: [main.Effect.apply(...)]
```

The implementation report records 19 passing Core tests. I did not rerun that existing suite or unrelated in-progress suites; the targeted harness tests new review hypotheses and changes no product or test source. Compiler caches were written under `/private/tmp/dont-sleep-core-review-module-cache`.

The review found no separate nominal-path defect in exact battery20/21 handling, exact lease30 expiry, repeated mode generations, stale apply/restore rejection, timer reset, clock rollback clamping, failed restoration remaining non-off, or recovery discarding old deadlines. Actuator serialization, original-baseline preservation, journal loading, authentic UI heartbeats, periodic delivery, and safe restoration retry timing remain explicit host obligations. Generation exhaustion is documented as requiring activation to remain blocked and adapter diagnosis; it is not claimed to be exercised by the nineteen tests.

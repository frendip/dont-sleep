# Native UI implementation report

Date: 2026-10-10. Scope: Sources/DontSleepApp, Tests/DontSleepAppTests, Resources/Assets.

## Implemented

Native SwiftUI MenuBarExtra with window style follows approved design B: 340 pt width, 16 pt padding, 30 pt mode rows, 14 pt semibold header, 13 pt information/action text and 12 pt secondary/banners. Seven modes appear in the approved order. Charge remains left; active timer remains right, including 100% + 8:00:00. App has no main window, manual startup and accessory activation policy.

AppModel uses the real authenticated XPCServiceClient, with serialized calls and coalesced power-event refresh. A new UI restores a preexisting session instead of renewing it. Explicit starts alone grant session ownership; OFF intent revokes ownership before stop RPC and persists through lost replies. Mode preference starts at permanent for each UI lifetime and retains explicit choices in that lifetime. No fixture fallback is used by normal startup.

Menu button, Command-Q command and NSApplication termination delegate all use the same stop-and-verify gate. Duplicate quit requests coalesce. Failure and disconnection remain visible and cannot manufacture verified OFF. A positively absent installation permits first-run exit only while the protected installation directory and both launchd plist paths all return ENOENT; partial/installed/unreachable states require verified restoration. A pending quit reevaluates positive absence after a canceled setup.

The closed verified-OFF app owns no polling timer. A passive native IOKit power observation triggers status refresh. Owned active sessions renew from main-actor work every five seconds; closed-menu UI does not tick each second. A separate visible display ticker keeps timer/power freshness progressing during awaited IPC. Recovery continues status observation without renewing the lease.

Setup and repair require an explicit Настроить… click. Installer bytes are captured before authorization and SHA256-checked against compiled InstallerProgram.pinnedSHA256. Root receives immutable captured bytes via a sanitized env -i /bin/bash --noprofile --norc -c command. Live SecCode identity is bound to the captured cdhash through an exact SecRequirement and SecCodeCheckValidity, then passed to the fixed installer for protected-stage verification. The final pin is 3c69528560b579fb7f7598a71eb6862a6f2900a0911a2d693848f5d58e46e240. No installer or administrator operation was executed by this UI task.

System low-battery notifications are posted only if already authorized, with recovery wording when OFF remains unverified. Notification permission is requested only following explicit successful setup. Denial leaves in-menu warnings and safety behavior intact. Persisted service stop reasons can explain interrupted previous sessions on the next launch.

A retained nonblocking flock provides the atomic single-instance gate. NSRunningApplication is used only to focus an existing process after lock contention; it cannot cause the winning lock holder to exit.

The eye is drawn natively as an NSImage template, with semantic warning/error badges. Error snapshots show a bolt only when current state proves active; failed restoration alone does not prove that. Vector app icon source, ten iconset PNG sizes, 1024 PNG and AppIcon.icns are supplied. No raster concept image is used as production artwork.

## Verification

Tests were written against deliberate skeletons and observed failing before implementation. Presentation six-test initial RED had 19 expected assertions; first model three-test RED had six expected failures. Follow-up regressions were observed RED for first-run verified absence, fresh UI mode preference, startup orphan restore, queued OFF, lost stop reply, immutable installer/quoting, atomic single-instance lock and pending quit after setup cancellation.

Commands used explicit SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk and Xcode's swift executable:

- Initial isolated presentation RED/GREEN: `swift test --package-path /tmp/dontsleep-ui-red --filter PresentationTests` (temporary isolation while IPC target was being implemented).
- Final whole-project suite: `swift test --scratch-path .scratch/ui-build` passed at 10:15:39.
- Final scoped suite after last reviewed UI changes: `swift test --scratch-path .scratch/ui-build --filter DontSleepAppTests` passed 19 tests at 10:21:06.985.
- `DontSleepApp --smoke-test` passed without service connection or power changes.
- `DontSleepApp --render-previews /Applications/projects/dont-sleep/.scratch/ui-previews` produced 20 native NSHostingView content images: active timer, OFF, low battery, restore error, permanent, enabling, restoring, setup, unknown and eight-hour AC stress case, in both appearances.
- `DontSleepApp --export-icon /Applications/projects/dont-sleep/Resources/Assets` produced native-drawn app icon assets.
- The signed-bundle-only `--verify-installation-payload` validates actual resources and live signing identity without prompting, connecting to services or executing the installer. Final release-bundle execution belongs to parent integration verification.

## Visual and accessibility scope

Native light/dark panel renders were inspected for layout, wrapping, mode completeness, error visibility, enabled/disabled distinctions and the 100%/eight-hour combination. No text overflow was found. Semantic foreground/surface colors, native controls, 30 pt row targets, text labels, keyboard shortcut routing, decorative-eye hiding and an explicit menu-extra accessible status label are implemented. Error meaning is carried by text and shape as well as color. No custom motion or transparency layer is present.

The offscreen hosting renderer presents native ON switches and some borderless control decorations in inactive-window gray even after native window activation attempts; the selected state is still positionally ON. These images verify composition and state representation, not the actual active menu's accent tint. Actual on-screen native-control accent, keyboard focus, VoiceOver ordering and system Increase Contrast/Reduce Transparency should be checked on the installed app. The preview harness does not claim those checks passed. Root installation, real sleep changes and lid-closed hardware behavior were not exercised here.

## Final App Nap reliability follow-up

An injected ActivityLease retains one ProcessInfo activity only for a connected, explicitly owned, verified-active session. Its sole option is userInitiatedAllowingIdleSystemSleep; system-sleep disable, display-sleep disable and latencyCritical flags are excluded. OFF/quit intent ends it before stop RPC; disconnection, failed/recovering/OFF snapshots end it. It cannot send or renew service heartbeats. Watchdog lease enforcement remains independent. The activity lifetime/options test first failed with six assertions; the model ordering test first failed with `[stop]` rather than `[begin, end, stop]`, before implementation. Final App tests include both regressions. Physical hidden-menu App Nap scheduling and idle CPU/energy behavior remain hardware verification tasks.

Final scoped verification after ActivityLease integration: `swift test --scratch-path .scratch/ui-build --filter DontSleepAppTests` passed 21 tests with zero failures at 10:24:13.138. This preceded the final heartbeat scheduling and mode-availability review corrections below.

## Final scheduling and availability corrections

Monitoring retains the same task while its visibility/session role is unchanged. Its heartbeat delay uses the remaining continuous five-second deadline, so menu opening, status refreshes and native power events cannot indefinitely postpone renewal. The last-heartbeat timestamp changes only after a serialized heartbeat call actually begins. A regression continuously refreshed status every 200 ms for six seconds; it first failed with zero heartbeats at 10:27:33, then passed after the scheduling correction.

Background serialized requests now disable mode and ON selection without disabling an active OFF switch or quit. The queued-OFF regression gained availability assertions, observed its expected failure at 10:30:28, and passed after the presentation correction. Final scoped command `swift test --scratch-path .scratch/ui-build --filter DontSleepAppTests` passed 22 tests with zero failures at 10:31:05.095. UI source is frozen for parent release integration.

# MotionKit — Known Bugs Log

Living document. Add an entry when you find one. Each entry has:
- **Symptom** — what user observes
- **Root cause** — what's actually happening
- **Repro** — minimum steps to trigger
- **Status** — open / fixed / workaround / wontfix
- **Related code** — file paths and line ranges

---

## 1. ProOnboardingFlowModelOne shows blank Apple ID privacy screen on first launch

- **Symptom**: Modded Motion launches to a grey window with empty content area; menu bar shows only "Motion". Project browser never appears.
- **Root cause**: Motion 6.0 routes its launch through `POFDesktopOnboardingCoordinator.runFlow` (in `ProOnboardingFlowModelOne.framework`). The flow first queries `POFPrivacyAcknowledgementGate.checkIsRequiredWithCompletion:` which on AMSKit hits Apple's services. For the modded bundle ID (`com.motionkit.motionapp`), AMSKit can't recognize the bundle and the gate never resolves, so onboarding stalls on `PrivacyAndSignUpContentView` (a SwiftUI host that renders blank). Motion blocks until onboarding completes, so the project browser never opens.
- **Repro**: Fresh launch of `~/Applications/MotionKit/Motion.app` via `open -na`. Probe `NSApp.windows.firstObject.contentView.subviews.firstObject.className` → returns `_TtGC7SwiftUI13NSHostingViewV25ProOnboardingFlowModelOne27PrivacyAndSignUpContentView_`.
- **Status**: fixed
- **Fix**: At `applicationDidFinishLaunching:` (Motion-host path), `Sources/SpliceKit.m` now swizzles three things:
  1. `-[POFPrivacyAcknowledgementGate checkIsRequiredWithCompletion:]` → invoke completion `(NO, nil)` immediately. Block signature is `(BOOL required, NSError *error)`, derived from type encoding `v24@0:8@?16` and the `POFPrivacyAcknowledgementGating` Swift protocol.
  2. `-[POFDesktopOnboardingCoordinator hasActiveLicense]` → return `YES` (suppresses paywall code paths).
  3. `-[POFDesktopOnboardingCoordinator runFlow]` → skip the entire state machine and call `[MGDocumentController newDocumentFromProjectBrowser:dictionaryForDefaultDocument]` to bring up Motion's normal template chooser.
- **Why we don't just call `displayMainWindow`**: That block is set by Motion's app delegate but expects state established mid-runFlow (welcome animation done, license cached, etc.) and is a no-op when called cold. `newDocumentFromProjectBrowser:` is what onboarding eventually calls organically, so we drive it directly.
- **Related code**: `Sources/SpliceKit.m` `SpliceKit_motionSkipPrivacyGate`, `SpliceKit_motionSkipOnboardingFlow`, `SpliceKit_bypassMotionPrivacyGateIfPossible`, `SpliceKit_bypassMotionOnboardingFlowIfPossible`.

## 2. `debug.eval` SIGSEGVs on primitive return values

- **Symptom**: `debug.eval expression="NSApp.windows.count"` crashes Motion with SIGSEGV.
- **Root cause**: The eval engine assumes every step returns an object pointer. When a step returns a primitive (NSUInteger, BOOL, etc.) the next step dereferences a non-pointer and segfaults.
- **Repro**: `call('debug.eval', expression='NSApp.windows.count')` against a live MotionKit bridge.
- **Status**: open
- **Related code**: `Sources/SpliceKitServer.m` `SpliceKit_handleDebugEval` (search for `handleDebugEval`)
- **Workaround**: Don't include primitive accessors in eval chains. Use only object-returning properties.

## 3. `system.getClasses` SIGSEGVs Motion when called with a `filter` parameter

- **Symptom**: `system.getClasses filter="Onboard"` crashes Motion.
- **Root cause**: TBD — likely nil-handling in the filter path or an unsafe class-list traversal.
- **Repro**: `call('system.getClasses', filter='Onboard')` against a live MotionKit bridge.
- **Status**: open
- **Related code**: `Sources/SpliceKitServer.m` `SpliceKit_handleSystemGetClasses`

## 4. Xcode overrides `DYLD_INSERT_LIBRARIES` from scheme

- **Symptom**: When Motion is launched from an Xcode workspace's scheme, MotionKit doesn't inject — only Xcode's own debug libs (libMainThreadChecker, libBacktraceRecording, libViewDebuggerSupport, libLogRedirect) appear in the env var.
- **Root cause**: Xcode rebuilds `DYLD_INSERT_LIBRARIES` from its diagnostic-flag settings (Main Thread Checker, View Debugger, etc.) and replaces any value set in the scheme's `<EnvironmentVariables>` block. Even chaining ours after Xcode's path didn't survive.
- **Repro**: Edit a `.xcscheme`'s `LaunchAction` to add `DYLD_INSERT_LIBRARIES` env var. Run from Xcode. Inspect `ps eww -p <pid>` — only Xcode's debug libs are present.
- **Status**: workaround (launch Motion via `open -na` first, then `Debug → Attach to Process by PID`)
- **Related code**: N/A (Xcode behavior)

## 5. Untitled-document creation triggers OZTimelineView runaway redraw

- **Symptom** (FIXED): Creating an empty Motion document via `makeUntitledDocumentOfType:`, `newDocument:`, or `openUntitledDocumentAndDisplay:error:` puts `OZTimelineView` into an infinite `drawRect:` loop. The CA::Transaction observer hogs the run loop indefinitely; every subsequent RPC times out.
- **Root cause**: Motion's `OZTimelineView::drawBackground:` repeatedly calls `OZFrameIterator::isBigFrame()` which mutates state that re-invalidates the layer, causing the run-loop CA observer to fire the same draw forever. Likely a Motion bug exposed by empty-timeline state.
- **Repro**: Force `[NSDocumentController newDocument:nil]` on a fresh Motion. Sample the main thread — entirely inside `CA::Transaction::commit → OZTimelineView drawRect`.
- **Status**: workaround in place
- **Related code**: `Sources/SpliceKitCommandPalette.m` `SpliceKitMotionCommandIsBlocked` (blocks the four selectors); `Sources/SpliceKit.m` `SpliceKit_disableMotionAutoOpenUntitled` (only fires when AUTOCREATE=1).

## 6. `motionBootstrapState` returned stale placeholder from background threads

- **Symptom** (FIXED): `system.ping` from any RPC client returned `state_pending=true` with hardcoded zeros for window_count/document_count/etc., even after Motion was fully launched.
- **Root cause**: `+motionBootstrapState` only computed a real snapshot on the main thread; from background threads it returned a placeholder unless a previous main-thread call had populated the cache. Nothing populated the cache periodically.
- **Status**: fixed
- **Related code**: `Sources/SpliceKitRuntime.m` (drain observer now calls `+refreshMotionStateCacheFromMainThreadIfReady` every ~500ms); `Sources/SpliceKitCommandPalette.m` (new class method).

## 7. Main-thread RPC starvation under CA::Transaction

- **Symptom** (FIXED): All RPC calls that needed main-thread access timed out at 2s, then a fail-fast flag locked all subsequent calls into instant-error mode.
- **Root cause**: Motion's run-loop is monopolized by `CA::Transaction::flush_as_runloop_observer`; `dispatch_async(main_queue)` and `CFRunLoopPerformBlock(commonModes)` never serviced our blocks. The 2s timeout was too short, and the silent fail-after-1-timeout prevented recovery.
- **Status**: fixed
- **Related code**: `Sources/SpliceKitRuntime.m` `SpliceKit_executeOnMainThread` (now routes through the event-pump queue + `CFRunLoopObserver` drain on Motion). Removed the silent fail.

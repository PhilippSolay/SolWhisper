# Swift / macOS API Correctness Review — SolWhisper Public Launch

Static review of the working tree on `feat/kiros-integration`. No app launches. Focus:
leaks, crashes, and API-misuse in a long-running background app — the class of bug friends
tolerate but a public audience won't. Top findings re-verified against code.

> Note: the single highest-severity concurrency bug — the audio tap buffer forwarded across
> an async `Task` (`MeetingAudioEngine.swift:130`) — is filed as **C1 in `02-architecture.md`**
> to avoid duplication. It belongs to both lenses.

## CRITICAL

### C1 — Force-cast on an Accessibility API result can crash the whole app on a paste
`Sources/Paste/PasteManager.swift:144` — **verified**
```swift
let focused = (focusedRef as! AXUIElement)
```
`AXUIElementCopyAttributeValue` returning `.success` guarantees non-nil, but **not** that the
`CFTypeRef` is an `AXUIElement`. Third-party apps with non-conformant AX implementations, or a focus
transition, can return a different CF type → `as!` is a hard crash, not catchable. This is method C of
a 4-method paste fallback chain, so it's reachable on normal dictation. A crash here takes down every
concurrent session (meeting, translate) and loses the in-flight transcript.

**Fix (one line):** `guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else { return false }`
before the cast.

### C2 — No `applicationWillTerminate` → dictation has zero crash-recovery
`Sources/App/AppDelegate.swift` — **verified absent** (no `applicationWillTerminate`/`ShouldTerminate`)

Quitting (`⌘Q`, Force Quit, logout) mid-dictation never calls `stopRecording()`; the active backend's
`AVAudioEngine` is torn down abruptly and the WhisperKit path's open `AVAudioFile` is never flushed →
truncated temp file, no recovery. Meetings have `CrashRecovery` (though see architecture C4 for its
gap); **dictation has no safety net at all**.

**Fix:** implement `applicationWillTerminate` to best-effort flush/persist any in-flight dictation to a
recoverable location, mirroring the meeting crash-recovery pattern.

## HIGH

### H1 — `CGEvent` tap in AdditiveClipboard never recovers from OS-forced disable
`Sources/Paste/AdditiveClipboard.swift:76,96,104` — **verified**

The callback only handles `type == .keyDown`. macOS disables event taps that run too long
(`.tapDisabledByTimeout`) or on certain input (`.tapDisabledByUserInput`) and delivers those through the
**same** callback — which this ignores. The `tapEnable(true)` at line 96 is the one-time setup enable;
there is no in-callback re-enable. Once disabled (system stall, another misbehaving tap), "clear on
paste" silently dies for the rest of the session and the clipboard keeps accumulating old dictations
with no indication.

**Fix:** in the callback, on `.tapDisabledByTimeout`/`.tapDisabledByUserInput` call
`CGEvent.tapEnable(tap:enable:true)` (capture `tap` via the `refcon` already threaded through).

### H2 — Deprecated microphone-permission API on a macOS-14-only app
`Sources/Transcription/TranscriptionController.swift:270`, `Sources/Meeting/MeetingController.swift:934` — **verified**

Uses `AVCaptureDevice.requestAccess(for: .audio)` (the camera/capture-device API) for mic-only auth.
Works today but the documented macOS 14+ path is `AVAudioApplication.requestRecordPermission()` /
`AVAudioApplication.shared.recordPermission`. Not yet `@available(deprecated)`, so there's no compile
warning to catch a future removal — swap it before it becomes a bug users can't fix without an update.

### H3 — Deprecated `NSUserNotification` makes the "permissions denied" prompt a dead end
`Sources/App/AppDelegate.swift:389-395` — **verified** (no `UNUserNotificationCenter` anywhere)

`NSUserNotification` has been deprecated since macOS 10.14; on current macOS it's often silently
swallowed by the notification daemon, and even when it renders, no delegate is wired to handle the
"Open Settings" action button — so it does nothing. The result: a user who denies mic/Accessibility
during onboarding gets no working path back to System Settings, and dictation silently does nothing.

**Fix:** migrate to `UNUserNotificationCenter` with a registered action category + a delegate that opens
the `x-apple.systempreferences:` URL (the correct pattern already exists in `ScreenCapture.swift`).

## MEDIUM

- **M1 — `PasteManager.paste` busy-polls `frontmostApplication` up to 0.8s per paste on the MainActor.**
  `PasteManager.swift:49-53`. It's `await Task.sleep` (yields, not a hard block — good), but ~27 × 30ms
  MainActor round-trips + a 150ms stabilize sleep + a 100ms pre-sleep in `AppDelegate.stopRecording`
  compounds into a visible >1s "why is dictation slow" delay against slow-activating targets (Electron
  apps), serialized ahead of other MainActor work. Cap the poll more aggressively (~400ms); methods A/B
  don't actually require the exact frontmost check.
- **M2 — `AVAudioPCMBuffer(...)!` force-unwrap in the meeting mixdown.** `MeetingController.swift:852-854`.
  Failable initializer force-unwrapped; very unlikely with fixed `block=4096` + a valid format, but under
  memory pressure on a 70-min recording it crashes deep in post-processing, after the user stopped, losing
  a captured meeting. `guard let … else { throw }` and let the existing `do/catch` handle it.
- **M3 — `AACMonoEncoder.append` busy-waits with `Thread.sleep(0.0005)` in an async context.**
  `AACMonoEncoder.swift:71-77`. Runs off-MainActor today (safe), but `Thread.sleep` in an `async` function
  can starve the cooperative pool if ever called from a shared-pool `Task`. Replace with
  `try? await Task.sleep(nanoseconds: 500_000)`.
- **M4 — Implicitly-unwrapped `updaterController!` / `secretsStore!` initialized outside `init`.**
  `AppDelegate.swift:16,19`. Assigned only in `applicationDidFinishLaunching`; any pre-launch access (early
  `EnvironmentObject` resolution, a reordered call) force-unwraps nil. Low risk under normal lifecycle, but
  a reorder-under-pressure trap. Prefer lazy-init closures (as `meetingController` already does).

## LOW

- **L1 — Deprecated `NSOpenPanel.allowedFileTypes`.** `AppDelegate.swift:822` sets `allowedContentTypes = []`
  (no-op) then uses the deprecated string-extension API. Build `[UTType]` and set only `allowedContentTypes`.
- **L2 — `CGEventSource` re-created per Cmd+V synth.** `PasteManager.swift:157`. Minor; not a leak.
- **L3 — `DeviceMonitor.stop()` nils `pinnedDeviceUID` but not `pinnedDeviceName`.** `DeviceMonitor.swift:65-72`.
  No effect today (both re-assigned on next `start()`); a stale-read trap for a future refactor.

## Reviewed and confirmed correct (no action)

Called out because they're the load-bearing risky bits and they're **done right**:
- `PreferredInputDevice` HAL teardown (Uninitialize-before-SetProperty, explicit release) across every
  exit path; `vDSP_DFT_Setup`/`DestroySetup` correctly paired at all 4 FFT sites.
- All `withCheckedContinuation` sites resume exactly once per path (ScreenCapture, AppleTranslation,
  Calendar, mic-permission) — no double/leaked continuations.
- `HotkeyManager` Carbon `RegisterEventHotKey`/`UnregisterEventHotKey` pairing is leak-free across
  re-registration and `deinit`; diff-gated re-registration is correct.
- `AdditiveClipboard.write`'s `changeCount`-guarded clear-on-paste race protection is correct.
- `CalendarIntegration` correctly branches `#available(macOS 14.0, *)` for full-access APIs.
- `AppleSpeechClient`'s 3s fallback-timer vs `isFinal` callback race is correctly guarded (both null
  `finalCB` before invoking, same queue).
- `MeetingTimeBucket` + epoch-minute build number are DST/timezone-safe by construction.
- All `NotificationCenter`/`NSEvent` observers in `TranslateResultBubble`/`OverlayWindowController` are
  removed in `deinit`.

## Top 5 stability fixes before launch

1. **Force-cast crash in `PasteManager.axInsert`** (C1) — one-line `CFGetTypeID` guard. Reachable on
   every dictation paste's fallback.
2. **Audio tap buffer race** (architecture C1) — deep-copy in the tap.
3. **No `applicationWillTerminate`** (C2) — dictation has zero crash-recovery.
4. **`NSUserNotification` dead-end permissions prompt** (H3) — migrate to `UNUserNotificationCenter` so
   denied-permission users can recover.
5. **AdditiveClipboard tap never re-enables** (H1) — add the `.tapDisabled*` handler.

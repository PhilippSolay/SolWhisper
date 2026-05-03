# Meeting Mode — Concurrency Design

**Status:** v0.4 baseline · Sprint 0 deliverable · normative for Sprints 4a/4b/5
**Goal:** Define which thread/queue/actor owns which state before any audio code is written, so we never hit a race that survives to a release.

This document is the contract. If a PR violates these rules, it's wrong — fix the PR, not the doc. The doc only changes when we have a profiler trace or a deadlock proving it should.

---

## 0. Why this exists

Meeting recording crosses every dangerous boundary at once:

- Real-time audio callbacks (must not block, must not allocate, must not touch SwiftUI)
- Two independent capture sources (mic via Core Audio, system audio via ScreenCaptureKit)
- Disk I/O every 30 seconds (chunk writes)
- LLM HTTP calls (post-processing, can take seconds-to-minutes)
- SwiftUI bindings (must run on `@MainActor`)
- Crash recovery (state must be reconstructable from disk alone)

Mode A (the dictation hot path) gets this right because there's only one source and one sink. Meeting mode multiplies the surface. Pin it down upfront.

---

## 1. Ownership rules (one paragraph version)

`@MainActor` owns UI state, settings, the tray menu, and the public `MeetingController.state` enum. Audio threads own raw PCM buffers and never call into `@MainActor` synchronously. The audio→main handoff is **always** an `AsyncStream` with a bounded buffer; if the consumer falls behind, we drop oldest, log a warning, and keep recording. Disk I/O lives on a background actor (`MeetingFileActor`) that is never awaited from `@MainActor` while audio is running. LLM calls are `Task.detached(priority: .userInitiated)` and surface results via `@MainActor` continuations. The audio callbacks themselves never lock, never allocate, never touch the file system.

---

## 2. The four execution domains

| Domain | Type | What it owns | What it must not do |
|---|---|---|---|
| **MainActor** | `@MainActor` | UI bindings, `MeetingController.state`, tray menu, settings reads, all `@Published` props | Block (`>16ms`); call audio APIs that may sleep; do file I/O |
| **AudioCallbackQueue** | Real-time thread (Core Audio + SCKit) | Live PCM ring buffers, RMS/peak meters, ducking gain | Allocate, lock, call Swift async functions, hold the buffer past the callback |
| **MeetingFileActor** | `actor` (background) | Chunk WAV writes, `meeting.json` reads/writes, `done.flag`, session.log | Touch SwiftUI; await `@MainActor` while audio is running |
| **PostProcessingTask** | `Task.detached` | LLM calls, summary generation, integration sends | Touch UI directly (use `await MainActor.run` for state changes) |

These are the only four domains. New code must belong to exactly one. If you need a fifth, propose it in this doc first.

---

## 3. Audio callback discipline

Audio callbacks come from Core Audio (mic) and ScreenCaptureKit (`SCStreamOutput.stream(_:didOutputSampleBuffer:of:)`) on real-time priority threads. They are sacred. The only operations allowed inside an audio callback:

- Read from a pre-allocated buffer
- Write to a pre-allocated lock-free ring buffer
- Compute simple DSP on the buffer (RMS, peak, mix gain)
- Atomic counter updates (`OSAtomicAdd`/`std::atomic`-equivalent in Swift)
- `os_unfair_lock_trylock` only as a backstop, never `lock()` blocking

Banned in audio callbacks:

- `Swift.print`, `os_log` at default level (use `os_signpost` for tracing instead)
- Any `Array` mutation that could grow capacity
- `DispatchQueue.async`, `Task { ... }`, `await`
- Reading `UserDefaults`, `FileManager`, `URLSession`
- Calling `MainActor` anything (even `MainActor.assumeIsolated`)

The audio callback's job is to **fill the ring buffer and return**. Everything else is downstream.

---

## 4. Audio → consumer handoff (the only sanctioned bridge)

Each audio source publishes its samples through an `AsyncStream<AudioBuffer>` with **bounded buffering policy `.bufferingNewest(N)`** where N is sized to one chunk-window worth of buffers (≈30 buffers at 50ms cadence for a 30s chunk).

```swift
// In MeetingAudioEngine
let (micStream, micContinuation) = AsyncStream.makeStream(
    of: AudioBuffer.self,
    bufferingPolicy: .bufferingNewest(60)   // 3s safety margin at 50ms buffers
)
```

Why this shape:

- Bounded — if `ChunkWriter` falls behind (disk stalls, GC pause), we drop oldest
  and log a "writer stall" event rather than blowing memory or blocking the audio thread
- Cancellation-safe — `MeetingController.stop()` cancels the consuming task,
  and `continuation.finish()` walks the chain cleanly
- No locks — `AsyncStream` uses internal lock-free queue

Consumers run as `Task` (not `Task.detached`) bound to the `MeetingFileActor` for chunk writes, and a separate `Task` for the meter UI:

```swift
// Disk consumer — bound to MeetingFileActor
Task {
    for await buffer in micStream {
        await meetingFileActor.append(buffer, to: .mic)
    }
}

// Meter consumer — runs at low priority, samples
Task(priority: .utility) {
    for await buffer in micStream {
        let rms = buffer.rms()
        await MainActor.run { self.micLevel = rms }
    }
}
```

**Note:** A single `AsyncStream` has one consumer. We use *two* streams per source (one to disk, one to UI) by tee-ing in `MeetingAudioEngine`, which costs one buffer copy. Acceptable: 50ms × 48kHz stereo Int16 = 9.6 KB; 1 GB/hour of copy throughput is nothing.

---

## 5. File I/O — `MeetingFileActor`

```swift
actor MeetingFileActor {
    private let chunkDir: URL
    private var chunkIndex: Int = 0
    private var micWriter: WAVChunkWriter
    private var sysWriter: WAVChunkWriter

    func append(_ buf: AudioBuffer, to channel: Channel) { ... }
    func rotate() async throws { ... }     // closes current chunk, opens next
    func finalize() async throws { ... }   // writes done.flag
}
```

Rules:

- **Never** awaited from `MainActor` while audio is recording.
  The MainActor calls `MeetingController.stop()`, which dispatches a stop intent;
  the controller awaits the actor on a non-MainActor task and reports completion back.
- All writes are atomic: write to `chunk-NNNN-mic.wav.tmp`, then `rename`.
- `done.flag` is the **only** signal that crash recovery uses to mean "clean stop".
  Don't write it earlier than the very last step.
- Errors propagate. `rotate()` failures stop the recording — partial chunk is
  better than corrupt chunk.

Reads (Transcripts window loading meeting list) use a separate `MeetingStoreActor`
because they don't share state with active recordings. Both are background actors;
reads from MainActor are explicit `await`s and shown with progress UI.

---

## 6. State machine and `MainActor` ownership

`MeetingController.state` is the public source of truth. It's a `@Published` property on a `@MainActor` `ObservableObject`. SwiftUI binds to it directly.

```swift
@MainActor
final class MeetingController: ObservableObject {
    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var deviceHealth: DeviceHealth = .healthy
    @Published private(set) var isClipping: Bool = false

    enum State: Equatable {
        case idle
        case starting
        case recording(meetingID: UUID)
        case paused(meetingID: UUID)
        case stopping(meetingID: UUID)
        case processing(meetingID: UUID)   // post-stop transcription/summary
    }
}
```

State transitions are **only** from `MainActor`. Background actors send back
events (chunk-rotated, writer-stalled, error) through a single
`AsyncStream<MeetingEvent>` that the controller drains on `MainActor`.
Background code never sets `state` directly.

---

## 7. Cancellation

Three things must be cancellation-correct:

1. **User clicks Stop while recording.**
   `state → stopping`. Continuation on every audio stream is finished.
   `MeetingFileActor.finalize()` is awaited (closes any open chunk, writes `done.flag`).
   Then `state → processing` and the post-processing task starts.
   If the user closes the app *during* `processing`, the meeting is preserved
   on disk; transcription resumes/repeats on next launch via crash recovery.

2. **User clicks Stop *during* a writer stall.**
   The stop path doesn't need to wait for the stalled writer to drain — it
   marks the stream as finished, lets the actor finish in-flight work, and
   returns. Worst case: the last 1-2 buffers are lost. Acceptable.

3. **App is force-quit during recording.**
   Nothing graceful runs. On next launch, `CrashRecovery` finds chunks/ folders
   without `done.flag` and offers recovery. Done.

`Task.cancel()` propagates through all `await`s. We do not poll `Task.isCancelled`
in audio code (that code can't await anyway). We *do* check `Task.isCancelled`
between LLM steps in `PostProcessingTask` to bail out if the user deletes the
meeting before summary completes.

---

## 8. LLM and integration calls

`PostProcessingTask` is `Task.detached(priority: .userInitiated)`. It:

1. Reads transcript segments from the `MeetingFileActor` (one await).
2. Runs cleanup pass — single LLM call, surfaces partial result to UI when done.
3. Runs summary generation — single LLM call.
4. Writes summary back via the actor.
5. Fires off integration sends in parallel `async let` blocks. Failures go to
   the durable retry queue; the main task does not await retries.
6. Posts a final `MeetingEvent.processingComplete` on the MainActor stream.

UI updates inside the task use `await MainActor.run { ... }` blocks. We do not
mark the task `@MainActor` — that would serialize cleanup behind UI work.

---

## 9. Settings reads

UI components read settings via `@AppStorage` / `SecretsStore` (both bound to
`@MainActor`). Audio/file actors never read settings directly. Instead, the
`MeetingController` snapshots all relevant settings into a `MeetingConfig`
struct at recording start and passes the immutable config through.

```swift
struct MeetingConfig: Sendable {
    let chunkSeconds: Int
    let enableDucking: Bool
    let enableClippingDetector: Bool
    let saveFolder: URL
    let micDeviceID: AudioDeviceID?
    let systemAudioFilter: SCContentFilter
}
```

This guarantees a recording can't behave differently halfway through if the
user toggles a setting mid-call.

---

## 10. Testing the rules

Each rule above maps to a specific test:

| Rule | Test |
|---|---|
| Audio callback no-allocation | Profiler instrument — zero malloc events during 1-min capture |
| AsyncStream bounded | Inject a 5s sleep into a fake disk consumer — verify "writer stall" event fires, recording continues |
| State machine MainActor only | `MainActor` isolation enforced by Swift 5.9 — compiler catches violations |
| Crash recovery | Force-quit via SIGKILL during recording — relaunch — recovery succeeds |
| Cancellation correctness | Unit test: stop during stall, verify done.flag still written |
| Config snapshot | Toggle a setting mid-recording — verify chunk N+1 still uses initial value |

Sprint 4a includes a "Concurrency conformance" test target. Sprint 4b extends it
for device-monitor races.

---

## 11. What's *not* in this doc

- WhisperKit's internal threading — opaque, treated as a third-party library
- AVAudioPlayer threading for transcript scrub — standard SwiftUI, low risk
- Sparkle's update threading — also opaque, runs on background dispatch internally

If problems show up in those areas, they get their own design notes, not edits to this one.

---

*Last reviewed: Sprint 0. Next review: end of Sprint 4a.*

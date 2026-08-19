# Meeting Mode — Concurrency Design

This doc has two parts: **what is actually built today** (authoritative), and the
**original target model** (aspirational — several of its primitives were never
implemented). Read Part A for how the code behaves; Part B is design intent kept
for reference and as a fast-follow backlog.

---

# Part A — As built (2026-07, authoritative)

The shipping meeting pipeline does **not** use the `MeetingFileActor` /
`MeetingStoreActor` / `MeetingConfig` / bounded-`AsyncStream` design in Part B.
What's actually there:

- **MainActor** owns UI state and `MeetingController.state` (a `@Published`
  enum on a `@MainActor ObservableObject`) — accurate to Part B §6, and the
  `State` enum there matches the code.
- **Audio taps** (mic via `AVAudioEngine`, system via `ScreenCaptureKit`) run on
  their own threads. Each captured buffer is **deep-copied on the tap thread**
  before crossing to the main actor (`MeetingAudioEngine.deepCopy`; the system
  path allocates a fresh `AVAudioPCMBuffer` in `SystemAudioCapture`), then
  forwarded via a per-buffer `Task { @MainActor … }`. There is **no** bounded
  `AsyncStream` and **no** drop-oldest backpressure — an unbounded `Task {}`
  fan-out plus `pendingMic`/`pendingSystem` arrays. (This is the H1/H2 concurrency
  debt in docs/launch-review/02-architecture.md; it works at current scale but
  isn't the bounded model below.)
- **Disk writes** go through `ChunkWriter`, which **is** an `actor` (so writes are
  serialized off the audio thread), but it is created inline by `MeetingController`
  — not a long-lived `MeetingFileActor`. Chunk files are written to `.tmp` and
  atomically renamed on close.
- **Settings are read live from `UserDefaults` mid-pipeline** (e.g.
  `MeetingPostProcessor` reads the `auto*` toggles at run time). There is **no**
  `MeetingConfig` snapshot, so toggling a setting mid-recording can affect a later
  stage. The one former exception (chunk size) is now a hardcoded 30 s constant.
- **Post-processing** runs as a stored `Task` (`MeetingController.processingTask`),
  cancellable on delete, with `Task.isCancelled` / folder-exists checks between
  stages (`MeetingPostProcessor`). Not `Task.detached`.
- **Crash recovery** keys off the presence of `transcript.json` (not `done.flag`,
  which is still written but no longer read) and recovers from surviving chunks or
  stitched audio. Imports are recovered separately (`CrashRecovery.interruptedImports`).

The launch-hardening passes fixed the concrete races this gap caused (tap buffer
deep-copy, ChunkWriter rotation index, cancellable + crash-recoverable
post-processing, writer-bootstrap failure surfaced). The full actor/bounded-stream
model remains a fast-follow.

---

# Part B — Original target model (aspirational; NOT all implemented)

> Everything below is the Sprint-0 target design. It is **not** a description of
> current behavior — the primitives named here (`MeetingFileActor`,
> `MeetingStoreActor`, `MeetingConfig`, bounded `AsyncStream` handoff, drop-oldest
> backpressure) do not exist in the code. Kept as design intent / backlog.

## 0. Why this exists

Meeting recording crosses every dangerous boundary at once: real-time audio
callbacks, two capture sources, periodic disk I/O, multi-second LLM calls, SwiftUI
`@MainActor` bindings, and crash recovery that must reconstruct state from disk.
The goal was to pin ownership down before writing audio code.

## 1. Ownership rules (target)

`@MainActor` owns UI state, settings, and `MeetingController.state`. Audio threads
own raw PCM and never call `@MainActor` synchronously. The audio→main handoff was
meant to be a **bounded `AsyncStream`** (drop-oldest on consumer stall). Disk I/O
was to live on a background `MeetingFileActor` never awaited from `@MainActor`
while audio runs. LLM calls were `Task.detached(.userInitiated)` surfacing results
via `@MainActor`.

## 2. Four execution domains (target)

| Domain | Type | Owns | Must not |
|---|---|---|---|
| MainActor | `@MainActor` | UI, `state`, settings | block >16ms, do file I/O |
| AudioCallbackQueue | RT thread | ring buffers, meters, gain | allocate, lock, `await` |
| MeetingFileActor | `actor` | chunk writes, `meeting.json` | touch UI, await MainActor mid-record |
| PostProcessingTask | `Task.detached` | LLM, summary, sends | touch UI directly |

## 3. Audio callback discipline (target)

Audio callbacks are real-time and sacred: read a pre-allocated buffer, write a
lock-free ring buffer, compute simple DSP, atomic counters only. Banned: `print`,
`Array` growth, `Task {}`/`await`, `UserDefaults`/`FileManager`/`URLSession`, any
`MainActor` access. Fill the ring buffer and return.

## 4–5. Handoff + file actor (target)

Each source was to publish through `AsyncStream<AudioBuffer>` with
`.bufferingNewest(N)` (drop-oldest + "writer stall" log), consumed by a `Task`
bound to `MeetingFileActor` (disk) and a low-priority `Task` (meters). `done.flag`
was the sole clean-stop signal (superseded in Part A by `transcript.json`).

## 6. State machine

The `MeetingController.state` enum (`idle`/`starting`/`recording`/`paused`/
`stopping`/`processing`) and its `@MainActor`-only transitions **are** as built.

## 7–10. Cancellation / LLM / settings snapshot / testing (target)

Cancellation correctness (stop, stall, force-quit) — the force-quit→crash-recovery
path is built (Part A); the stall/drop-oldest path is not (no bounded stream).
`MeetingConfig` snapshot (§9) is **not** built — settings are read live. The
conformance test target (§10) was not built.

---

*Part A last reviewed 2026-07. Part B is the original Sprint-0 target, retained as backlog.*

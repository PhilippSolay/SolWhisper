# SolWhisper — Full App Code Review (v0.6 audit)

Date: 2026-05-03
Scope: bugs, orphans, AI slop, slow code, race conditions, test coverage.

## Summary

129 tests pass across 13 suites. Three CRITICAL crash-class bugs were fixed in
production code, ~85 lines of dead code were removed, and 71 new unit tests
were added for the most logic-heavy modules (CleanupPass, DiarizationMapper,
SkillPack, VoiceMatcher, HomeStats).

## Critical fixes landed

| # | File / line | Problem | Fix |
|---|-------------|---------|-----|
| 1 | [WhisperKitClient.swift:316](../Sources/Transcription/WhisperKitClient.swift#L316) | `try!` on regex compilation crashes the app if pattern ever drifts | switched to `try?` + `guard let` with original-string passthrough |
| 2 | [MeetingController.swift:167](../Sources/Meeting/MeetingController.swift#L167) | `AVAudioFormat(...)!` crashes the recorder if mic returns 0-channel/0-Hz | `guard let` with `DebugLog` warning and graceful abort |
| 3 | [MeetingStore.swift:188](../Sources/Storage/MeetingStore.swift#L188) | `FileHandle` leaks if `seek` or `write` throws mid-call | `defer { try? handle.close() }` so it always closes |
| 4 | [SettingsView.swift:235-318](../Sources/Settings/SettingsView.swift#L235-L318) | `#if false ... _DELETE_AIPolish_DEAD ... #endif` (~85 lines of stale UI code) | deleted |

## New test suites

| Suite | Count | Covers |
|-------|-------|--------|
| [CleanupPassTests](../Tests/SolWhisperTests/CleanupPassTests.swift) | 17 | chunking (50/batch), JSON-object + array fallback parsing, artifact pre-filter regex (`[coughing]`, `(birds chirping)`, `<music>`), missing-index tolerance, Report fields (modified/unchanged/blanked counts, word-reduction %, provider label inference), forceAllRulesIfEmpty override |
| [DiarizationMapperTests](../Tests/SolWhisperTests/DiarizationMapperTests.swift) | 13 | first-appearance letter assignment, >26 speakers overflow to S26/S27, time preservation, 20% overlap threshold (under/at/over), aggregated overlap from same speaker, zero-length segment, non-speaker fields preserved |
| [SkillPackTests](../Tests/SolWhisperTests/SkillPackTests.swift) | 12 | YAML frontmatter parser (with/without fences, colons in values, padded keys), renderPrompt with known/unknown/nil meeting type, context block inclusion when present, omission when whitespace |
| [VoiceMatcherTests](../Tests/SolWhisperTests/VoiceMatcherTests.swift) | 16 | cosine similarity (identical/orthogonal/opposite/known-angle), zero/empty/mismatched inputs, magnitude invariance, threshold guard at 0.70, Float↔Data round-trip, hasEmbedding flag for nil/empty/zero-dim |
| [HomeStatsTests](../Tests/SolWhisperTests/HomeStatsTests.swift) | 13 | empty entries → "—", lifetime WPM weighted by totals, "0" vs "—" for empty week with persisted entries, calendar week filter, unique app bundleIDs (nil excluded), duration formatting (seconds/min/hours), thousands grouping |

Total new tests: **71**.
Total suite: **129 tests, 0 failures, ~67s wall**.

## Run instructions

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
    -project SolWhisper.xcodeproj \
    -scheme SolWhisper \
    -destination 'platform=macOS' \
    -quiet
```

## Outstanding (not blocking)

These were flagged during audit but left for a future pass:

- ~11 `DateFormatter` instantiation sites that could share a single utility.
- Duplicate `JSONEncoder`/`JSONDecoder` setup in `MeetingStore` and
  `DictationHistory` — small, non-urgent.
- Several views use `@StateObject` for shared singletons (e.g.
  `VoiceProfileStore.shared`); should be `@ObservedObject` so the singleton
  isn't owned-and-recreated by the view's lifecycle.
- WhisperKit Swift-6 `Sendable` warnings around `InstanceCache` — upstream
  fix required.

## What was deliberately not touched

- `cosine(_:_:)` in [VoiceMatcher.swift](../Sources/People/VoiceMatcher.swift)
  was changed from `private static` to `static` to enable unit tests of the
  similarity math. This is the only production-code visibility change.
- The async paths in `MeetingDetailView` were investigated for stale-transcript
  reads; `.id(meeting.id)` already bounds the lifetime of in-flight tasks, so
  no fix was applied.

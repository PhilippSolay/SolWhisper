# Test coverage

## Baseline (before this review)

- **Tests executed:** 129
- **Failures:** 0
- **Time:** ~7.2 seconds (on this machine, Xcode 26.4.1)

## After this review

Identical: 129 passing, 0 failures, ~7.2 seconds.

I did not add new tests in this review pass — see [OPEN_QUESTIONS.md](./OPEN_QUESTIONS.md) for why. Below is the coverage map I built while reading, so the next pass can target the gaps deliberately.

## What's tested

| Test file | Targets | Notes |
|---|---|---|
| `CleanupPassTests.swift` | `CleanupPass` | Batching, mock `LLMClient`, response parsing. Strong coverage. |
| `CrashRecoveryTests.swift` | Crash-recovery scan | Orphan chunks → recovery flow. |
| `DiarizationMapperTests.swift` | Diarization → transcript mapping | Pure-logic mapper. |
| `HomeStatsTests.swift` | Week-bucket stats | Anchored to a known Sunday; deterministic. |
| `KeychainStoreTests.swift` | `KeychainStore` + `SecretsStore` migration | Includes `SecretsStoreMigrationTests` covering UserDefaults→Keychain. |
| `MeetingStoreTests.swift` | `MeetingStore` | CRUD on disk-backed store. |
| `MeetingTimeBucketTests.swift` | Time-bucket grouping | Sort + group logic. |
| `OCRPostProcessorTests.swift` | `OCRPostProcessor` | `.keep` and `.remove` modes, paragraph detection. |
| `SchemaMigrationTests.swift` | `SchemaMigration` + stamping | Schema-version round-trips. |
| `SkillPackTests.swift` | `SkillPack.parseModule`, `renderPrompt` | Frontmatter parsing, prompt rendering across all branches. |
| `VoiceMatcherTests.swift` | `VoiceMatcher.cosine`, `VoiceProfileEmbedder` | Cosine edge cases (orthogonal, opposite, zero, identical, normalization), data round-trip. |
| `WhisperKitClientTests.swift` | `WhisperKitClient` static surface | Model list, `stripSpecialTokens`, file-transcribe rejection of missing files, models directory creation. **Excludes** actual model loading + transcription. |

## What's not tested (and why each one is reasonable to skip — or not)

### Reasonably skipped (needs hardware / network / large fixtures)

- `Audio/AudioEngine`, `Transcription/AppleSpeechClient`, `Transcription/DeepgramClient` — depend on `AVAudioEngine` input nodes and the speech / WebSocket APIs.
- `Meeting/MeetingAudioEngine`, `SystemAudioCapture` — depend on `ScreenCaptureKit` and live mic.
- `Transcription/WhisperKitClient.fileTranscribe` — requires loading a real CoreML model (excluded explicitly in the test file's doc comment).
- `Diarization/FluidAudioDiarizer`, `AssemblyAIDiarizer`, `DeepgramDiarizer` — depend on the external diarizer + network.
- `LLM/*` clients — network and credentials.
- All SwiftUI views — covered by manual QA only.
- `HotKey/HotkeyManager` — Carbon hotkey APIs, system-level.
- `Integrations/*` — webhook delivery to external services.

### Could be tested cheaply but isn't

These are pure-logic functions or thin wrappers that could be unit-tested without hardware:

| Target | Why it's worth testing |
|---|---|
| `MCP/MCPTools.parseISO` | Pure date parser; one-line test. |
| `MCP/MCPStorage.searchTranscripts` snippet boundaries | Fixture transcript on disk; assert snippet contains the match and the trailing/leading context. **Would catch bug #3 in `BUGS_FOUND.md` (locale fold mismatch).** |
| `MCP/MCPTools` JSON-shape contract | `tools/list` and `tools/call` response shapes are part of the public surface to Claude Desktop / Cursor — a contract test (snapshot JSON of `MCPTools.all`) would catch accidental schema drift. |
| `Audio/AudioEngine` FFT bin mapping (`computeSpectrum`) | Synthetic sine input → assert energy in the right bin. The 300–3000 Hz log-spaced mapping is non-trivial and easy to regress when tuning. |
| `Audio/AudioFeedback.PlaybackController` duck/restore | Save+restore symmetry with the savedVolume guard suggested in `BUGS_FOUND.md` #11. |
| `Meeting/MeetingController.mixToCombined` | Pure-audio mix on disk; could write two short WAVs and assert the output is a frame-by-frame average (or ducked, with toggle off). |
| `Diarization/SpeakerNameSuggester.suggest` JSON parser | Inject a stub `LLMClient` that returns canned JSON; assert parsing handles missing/garbled fields. |
| `Transcription/DeepgramClient.handleJSON` parsing | Pure JSON-shape → callback dispatch. Inject the WebSocket layer and assert `onTranscript` is called with the right `(text, isFinal)` for each input. |
| `Transcription/WhisperKitClient.stripSpecialTokens` | Already partially tested. Could add: tokens at start, tokens at end, nested-looking tokens. |
| `PostProcessing/CleanupPass.cleanOneBatch` JSON extract | Tested indirectly; direct tests on `extractJSONObject` / `extractJSONArray` would lock in tolerance to LLM prose preambles. |

### Suggested ordering for the next pass

1. **MCP contract test** — highest leverage, cheapest. A snapshot of `MCPTools.all` + a search-snippet test would catch the `BUGS_FOUND.md #3` bug before the next release.
2. **SpeakerNameSuggester parser** — protects against LLM-format drift, which is the most volatile dependency.
3. **DeepgramClient.handleJSON** — would also serve as the regression test for the race bug (`BUGS_FOUND.md #2`) once it's fixed.
4. **AudioEngine FFT bin mapping** — protects the consolidation work suggested in `BUGS_FOUND.md #5`.

## Coverage-instrumentation note

`xcodebuild test` was run without `-enableCodeCoverage YES` for this review — running with it on Xcode 26 was producing a large `.xcresult` bundle on each run, and I wanted to keep the iteration cycle tight. A real coverage number would require:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project SolWhisper.xcodeproj -scheme SolWhisper \
  -configuration Debug -destination 'platform=macOS' \
  -enableCodeCoverage YES test
```

then `xcrun xccov view --report --json <path>.xcresult` for the JSON output.

# TEST_COVERAGE — map + before/after

Baseline: 132 Swift files / 25,096 lines under `Sources/`; **29 → 30** test files under `Tests/SolWhisperTests`
(added `ChunkWriterTests` this pass). Suite: **248 tests, 0 failures** on the review branch.

Coverage here is by presence of behavior tests per module (name-match / type-grep), not line %. macOS unit tests
don't exercise SwiftUI views, so view files are marked "no unit target" rather than untested-by-omission.

## Before / after this pass
| Module | Before | After | Δ |
|---|---|---|---|
| Meeting | `ChunkWriter` untested (rotation path zero coverage) | `ChunkWriterTests` added — rotation naming + no-.tmp invariant | +1 file, closes the fixed bug's regression gap |

No other coverage changed — the remaining HIGH items are held for the Phase 6 fix loop, where each fix lands with
its own test (paste delivery, dictation-persist-on-quit, import recovery, translate pack selection).

## Module coverage map
| Module | Files | Tested | Notable untested (launch-relevant) |
|---|---|---|---|
| App | 5 | 0 | AppDelegate, PermissionsNotifier |
| Audio | 3 | 0 | AudioEngine |
| Diarization | 9 | 1 | AssemblyAIDiarizer, DeepgramDiarizer, DiarizationResolver |
| HotKey | 1 | 0 | **HotkeyManager.registerHotKeys** (app unusable if it silently fails) |
| Import | 3 | 0 | FileImportController, ImportQueue, FileTranscriber (all new) |
| Integrations | 14 | 5 | **MustacheRenderer** (webhook escaping), CustomWebhook, OutboundWebhook, ObsidianIntegration, MCPTokenStore |
| LLM | 11 | 2 | provider clients, LLMRetry, ModelStore |
| Meeting | 13 | **4** (+ChunkWriter) | MeetingController state machine, MeetingPostProcessor, MeetingAudioEngine, SystemAudioCapture, **DeviceMonitor** |
| OCR | 5 | 1 | ScreenSnipperController, TextRecognizer |
| Paste | 2 | 0 | **PasteManager**, AdditiveClipboard |
| People | 5 | 4 | VoiceProfileStore |
| PostProcessing | 7 | 2 | SummaryGenerator, SkillPackLoader, SkillsRegistry |
| Security | 2 | 2 | — fully covered |
| Settings | 15 | 1 | 14 SwiftUI views (no unit target) |
| Storage | 9 | 6 | DictationHistory, **RetentionSweep** (irreversible deletion), TranscriptMarkdown |
| Transcription | 5 | 2 | **TranscriptionController** state machine, DeepgramClient |
| Transcripts | 11 | 2 | MeetingDetailView + views (no unit target) |
| Translate | 8 | 4 | AppleTranslationEngine, TranslationController |
| MCP | 4 | 0 | MCPServer, MCPStorage, MCPTools |

## 10 launch-critical untested behaviors (priority order for coverage debt)
1. `TranscriptionController` state machine (backend switch, start/stop) — core dictation, holds the `finish(nil)` swallow.
2. `PasteManager` 3-method fallback delivery — the payoff of dictation; holds the wrong-app + silent-osascript bugs.
3. `MeetingController.startInternal`/pipeline/recovery (180-line state machine) — only a peripheral audio helper tested.
4. `ChunkWriter` init-failure path (`MeetingController:342-345`) — the rotation bug is now tested; the nil-writer path (H-4) is not.
5. `MustacheRenderer` — the exact "webhook escaping" risk class, zero tests.
6. `CustomWebhook` + `OutboundWebhook` — per-webhook Keychain secret + HTTP delivery, zero tests.
7. `RetentionSweep` — auto-deletes meetings by age; irreversible; zero boundary tests.
8. `DeviceMonitor` — mid-meeting audio-device change; zero tests.
9. `HotkeyManager.registerHotKeys` — global hotkey; app unusable if it silently fails.
10. `IntegrationFanout` auto-integrate discard path — only the `Result` struct is tested, not the discard behavior.

**Well-covered, verified (named risk areas from the brief):** `CrashRecovery` scan logic and `SecretsStore`
Keychain migration both have real tests. Security module fully covered.

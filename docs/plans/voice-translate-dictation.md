# Plan — Voice Translate Dictation (speak in → output in another language)

**Branch:** `feature/translate-dictation`
**Worktree:** `/Users/philippsolay/code/solwhisper-translate-dictation`

## Goal

A sibling to the existing **STT Short** dictation feature. The user holds a
**new global hotkey**, speaks, and on release SolWhisper transcribes the speech
and pastes the **translation in a chosen target language** (instead of the raw
transcript). The target language is picked from a **dropdown**, with a
**default** configured in Settings.

This reuses two existing subsystems already in the codebase:
- **STT capture** — `Sources/Transcription/TranscriptionController.swift`
  (Apple Speech / Deepgram / WhisperKit backends).
- **Translation** — the engine model from
  `Sources/Translate/` (Apple `TranslationSession` + `LLMTranslationEngine`).

## Requirements (from brief)

1. Same behavior as STT Short, but output is translated. **Distinct hotkey.**
2. **Language dropdown** in the feature UI + **default target language** in Settings.
3. **Expanded, easily extensible language set.** Add: Farsi, Japanese, Russian,
   German, Italian, Korean, Chinese (Chinese already present). Single
   source-of-truth list so adding a language is a one-line change.
4. **Engine ("TTS model") switching matters.** Two engines exist: **Apple
   Translation** (on-device; downloads ~50 MB language packs per pair on first
   use via `TranslationSession.prepareTranslation()`) and **AI model / LLM**
   (cloud, no download). Language *availability/downloads are Apple-only*. The
   dropdown + settings must reflect per-engine availability and **degrade
   gracefully**.

   **Supported languages depend on the selected model (checked).** There is no
   per-model language metadata in the codebase — models are user-configured
   (`ModelStore`, any provider + free-text model IDs), so an LLM's language
   coverage is not programmatically enumerable. A static per-model table would
   be brittle and stale. Decision: answer readiness by **provider class** of the
   resolved translation model instead:
   - **Apple** → exact, via `LanguageAvailability`: `ready` / `needs download` /
     `not available`.
   - **LLM, frontier cloud** (Anthropic/OpenAI/Google/Groq/OpenRouter) → `ready`.
   - **LLM, local Ollama** → `depends on model` (coverage varies by model size).
   - **LLM, custom / no model configured** → `not available` (unroutable).
   `LanguageReadiness` carries a `.modelDependent` case + a `hint` string the
   settings dropdown renders next to each language.

## Key files (verified)

| Concern | File |
|---|---|
| Language list (curated, 5 today) | `Sources/Translate/TranslationLanguage.swift` |
| Engine kind enum (`apple`/`llm`, `translateEngine` key) | `Sources/Translate/TranslateResultBubble.swift:315` |
| Apple `TranslationSession` + download trigger | `Sources/Translate/TranslateResultBubble.swift:775` |
| LLM translation engine | `Sources/Translate/LLMTranslationEngine.swift` |
| Translation controller (state machine) | `Sources/Translate/TranslationController.swift` |
| STT capture controller | `Sources/Transcription/TranscriptionController.swift` |
| Hotkey registration (Carbon) | `Sources/HotKey/HotkeyManager.swift` |
| Hotkey defaults + wiring | `Sources/App/AppDelegate.swift` (~57–91, 519–551) |
| Settings shell + sections enum | `Sources/Settings/SettingsView.swift` |
| Hotkey settings UI | `Sources/Settings/SettingsView.swift` (~313, `HotkeySettingsView`) |
| Translate settings UI | `Sources/Settings/TranslateSettingsView.swift` |

No formal "Modes" abstraction exists — each feature is its own controller with
its own hotkey/settings/UI. Follow that pattern: **add a new controller**, do
not invent a mode system.

## Design

### Engine abstraction (refactor first, small)
Extract the engine concept so both the existing Translate-from-screen bubble and
the new voice feature share it:
- A `TranslationEngine` protocol with `translate(_ text:, from:, to:) async throws -> String`.
- Concrete `AppleTranslationEngine` (wraps `TranslationSession`) and existing
  `LLMTranslationEngine`.
- A `LanguageAvailability`-backed helper: `func availability(for code:, engine:)
  -> .ready | .needsDownload | .unsupported`. Apple uses Apple's
  `LanguageAvailability`; LLM returns `.ready` for every curated language.
- Keep `TranslationEngineKind` (`apple`/`llm`) as the user-facing toggle; reuse
  `translateEngine` UserDefaults key OR a new `voiceTranslateEngine` key (decide:
  share vs separate — default to a **separate** key so the two features can use
  different engines).

### New controller
`Sources/Transcription/VoiceTranslateController.swift`
- State: `idle → recording → recognizing → translating → done/error`.
- On hotkey: snapshot frontmost app as paste target, start STT capture (reuse
  `TranscriptionController` flow / backend selection).
- On stop: take final transcript → translate to the configured target via the
  selected engine → paste translated text through the existing paste/clipboard
  path (respect the same auto-paste/clipboard settings as STT Short).
- Immutable state updates (no in-place mutation), errors surfaced to UI, never
  swallowed.

### Language list (extensible)
Edit `Sources/Translate/TranslationLanguage.swift`:
- Extend `curated` to add: `fa` Farsi, `ja` Japanese, `ru` Russian, `de` German,
  `it` Italian, `ko` Korean. (`zh-Hans` Chinese already present.)
- Keep it one entry per line — that's the "easy way to add" knob. Document at the
  top that this single array drives every dropdown + the settings default.

### Hotkey
`Sources/HotKey/HotkeyManager.swift`:
- New hotkey ID `7`, `onVoiceTranslateHotkeyPressed` callback.
- UserDefaults keys: `voiceTranslateHotkeyKeyCode`, `voiceTranslateHotkeyModifierMask`.
- Register in `registerHotKeys()`, dispatch in the Carbon handler.
- Default suggestion: ⌃⌥⌘J (pick an unused keyCode; verify against the 6 existing).
- `AppDelegate`: register defaults + wire `onVoiceTranslateHotkeyPressed →
  startVoiceTranslate()`.

### Settings UI
New section `Sources/Settings/VoiceTranslateSettingsView.swift` (add case to the
sections enum in `SettingsView.swift`):
- **Engine** picker (Apple vs AI model) — mirror `TranslateSettingsView`, with
  the same footer explaining Apple downloads vs LLM-any-language.
- **Default target language** picker over `TranslationLanguage.curated`.
- Per-engine availability hint next to each language (or on selection): show
  "needs download" / "LLM only" when the chosen engine can't serve it on-device.
- Hotkey row added to `HotkeySettingsView`.

### Output UX
v1: paste translated text directly (parity with STT Short). Optional later:
reuse/adapt `TranslateResultBubble` to show source + translated before paste.

## Implementation phases (loop iterations)

Each phase = one focused, buildable iteration. After each: `xcodegen generate`
then `xcodebuild ... build`, fix errors before moving on.

1. **Languages** — extend `TranslationLanguage.curated` (+ doc comment). Build.
2. **Engine abstraction** — extract `TranslationEngine` protocol + `Apple`/`LLM`
   impls + availability helper. Keep existing bubble working. Build.
3. **Hotkey** — add ID 7, callback, defaults, Carbon dispatch, AppDelegate wiring. Build.
4. **Controller** — `VoiceTranslateController` (capture → translate → paste).
   Wire `startVoiceTranslate()` in AppDelegate. Build.
5. **Settings** — `VoiceTranslateSettingsView` + sections enum case + hotkey row
   + per-engine availability hints. Build.
6. **Tests** — unit tests: language list integrity, engine availability mapping
   (Apple needs-download vs LLM ready), controller state transitions (mock
   engine). Target the project's 80% bar on new code.
7. **Manual verify** — run app, exercise new hotkey end-to-end for Apple +
   LLM engines and 2–3 languages incl. one needing download.

## Verification status

- ✅ **Build**: `xcodebuild … build` green after every phase.
- ✅ **Unit tests**: 16 offline/deterministic tests pass (language-list
  integrity + expanded languages, readiness hints, provider-class LLM
  availability incl. `modelDependent`, controller defaults + passthrough).
- ✅ **App smoke test**: the worktree Debug build launches without a startup
  crash (hidden launch, 5 s, clean quit).
- ⚠️ **Human verification still required** — the headless `AppleTranslationEngine`
  is wired but cannot be exercised offline/in CI: it needs a real mic session
  (speech capture) **and** a downloaded on-device language pack for the chosen
  pair. To confirm end-to-end: assign the Voice Translate hotkey in Settings →
  Hotkey, pick a target language in Settings → Voice Translate (Apple engine),
  speak, and confirm the translated text pastes (first use of a pair triggers
  the macOS ~50 MB pack download prompt). Also confirm the LLM engine path with
  a configured cloud model.

## Constraints / coding standards
- Immutability; small files (<400 lines), small funcs (<50 lines).
- Explicit error handling, user-friendly messages, no silent failures.
- MainActor isolation for UI updates; async/await for capture + translate.
- No new dependencies; no network beyond the existing LLM routing.

## Sequencing decision — Apple engine first (per Philipp)
- **v1 default engine = Apple** on-device Translation. `voiceTranslateEngine`
  UserDefaults defaults to `apple` (factory falls back to LLM only when Apple is
  unavailable, i.e. macOS < 15).
- Get the **Apple path working + verified end-to-end** (hotkey → STT → headless
  Apple translate → paste) before fleshing out the LLM engine UX. The headless
  Apple host (`AppleTranslationEngine`) is the riskiest piece — Phase 7 manual
  verify must confirm it actually produces output in a real app run.
- Output stays **pasted text** (no spoken audio / AVSpeechSynthesizer — confirmed).

## Open decisions (sensible defaults chosen, revisit if needed)
- **Separate engine + hotkey + default-language keys** from Translate-from-screen
  (chosen: separate, so the two features are independent).
- **v1 pastes directly**, no bubble (chosen: parity + speed; bubble is a fast-follow).

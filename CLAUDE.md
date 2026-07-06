# SolWhisper — Claude Code Configuration

## Project
- **Product:** SolWhisper — macOS menu-bar app for dictation, meeting recording
  (mic + system audio), speaker diarization, translation, OCR/snip, LLM
  summarization, and task-extraction integrations.
- **Stack:** Swift + SwiftUI + macOS native APIs
- **Xcode project:** SolWhisper.xcodeproj
- **Build system:** project.yml (XcodeGen)

## Architecture
```
SwiftUI menu-bar app (macOS, LSUIElement)
  Dictation:  Speech framework / WhisperKit / Deepgram → LLM polish → paste (Accessibility)
  Meetings:   mic AVAudioEngine + system audio (ScreenCaptureKit) → chunk writer
              → stitch → WhisperKit transcribe → cleanup → diarize → summary → fanout
  LLM layer:  LLMResolver → LLMClient (OpenRouter, Anthropic, OpenAI, Groq, Google, Ollama)
  Storage:    file-per-meeting JSON under ~/Library/Application Support/SolWhisper/
  Integrations: IntegrationFanout → Kiros, Hermes, Obsidian, custom webhooks
  MCP:        bundled solwhisper-mcp binary exposes transcripts to Claude Desktop/Cursor
  Updates:    Sparkle (EdDSA-signed appcast)
```

### Key directories
- `Sources/` — Swift source files
- `Resources/` — Assets, localizations
- `design/` — Design specs and mockups
- `scripts/` — Build and release scripts

## Build & run
```bash
# Generate Xcode project from spec
xcodegen generate

# Build from command line
xcodebuild -project SolWhisper.xcodeproj -scheme SolWhisper -configuration Debug build

# Or open in Xcode
open SolWhisper.xcodeproj
```

## Key patterns
- SwiftUI views: small, composable, under 100 lines each
- State management: @State for local, @StateObject for view models, @EnvironmentObject for app-wide
- Concurrency: async/await with MainActor isolation for UI updates
- Accessibility API: requires user permission grant in System Settings > Privacy
- Speech recognition: requires microphone permission, handles session lifecycle

## Modes system
- Each mode defines context-specific transcription behavior
- Modes affect: output formatting, keyboard shortcuts, UI presentation
- Mode switching via menu bar or keyboard shortcut

## Security & permissions
- Accessibility API: entitlement required, graceful degradation if denied
- Microphone / Speech Recognition / Screen Recording / Calendar: runtime prompts, clear purpose strings
- API keys stored in Keychain (via SecretsStore + KeychainStore)
- **Network access IS used** — cloud STT (Deepgram, AssemblyAI), LLM providers, Sparkle
  appcast, and user-configured integrations (Kiros, Hermes, Obsidian, webhooks). Local-only
  is possible (Apple Speech + WhisperKit + Ollama) but not the default.
- **NOT sandboxed** — no `com.apple.security.app-sandbox` entitlement (needs Accessibility +
  Apple Events + arbitrary file paths for Obsidian/imports). This is a known trade-off; see
  docs/launch-review/03-security.md.

## What Claude can't infer
- XcodeGen generates the .xcodeproj from project.yml — edit project.yml, not Xcode settings.
  Adding a NEW source file requires re-running `xcodegen generate` before it builds.
- Releases are manual via scripts/release.sh (Sparkle + notarization); not CI/CD yet
- Dependencies use SPM (declared in project.yml): Sparkle, WhisperKit, FluidAudio, MarkdownUI
- MCP server IS implemented — `solwhisper-mcp` target, bundled into the app, gated by a token
  (SOLWHISPER_MCP_TOKEN); see Sources/Integrations/MCPTokenStore.swift and MCP/

# SolWhisper — Claude Code Configuration

## Project
- **Product:** SolWhisper — macOS dictation and transcription app
- **Stack:** Swift + SwiftUI + macOS native APIs
- **Xcode project:** SolWhisper.xcodeproj
- **Build system:** project.yml (XcodeGen)

## Architecture
```
SwiftUI app (macOS)
  → Speech framework (live transcription)
  → Accessibility API (text injection into any app)
  → Menu bar integration (always-available)
  → Modes system (context-specific behavior)
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
- Microphone: runtime permission prompt, clear purpose string
- No network access required (local-only processing)
- Sandboxed: no access to filesystem outside app container

## What Claude can't infer
- XcodeGen generates the .xcodeproj from project.yml — edit project.yml, not Xcode settings
- DMG installer at SolWhisper-v0.1.0.dmg (manual release, not CI/CD yet)
- MCP server integration is P1 roadmap — not yet implemented
- No package manager (SPM) yet — dependencies are minimal and vendored

# SolWhisper — Screen-OCR Feature Plan

**Author:** drafted 2026-05-03
**Target version:** v0.5.0 (or v0.4.0-alpha.3 if it slots before notarized GA)
**Inspired by:** [TextSniper](https://textsniper.app) — $7.99 Mac OCR utility ⌘⇧2-to-snip
**Scope:** Add a screen-region OCR mode to SolWhisper. User presses a hotkey, drags a marquee, gets the recognized text on the clipboard. New Settings section with "Keep / Remove line breaks" toggle and a few related controls. Reuses SolWhisper's existing hotkey, paste, and Settings infrastructure.

---

## 1. Five-second summary

You're adding ~5 new focused Swift files (~1.5–2k LOC) plus one Settings section. Net cost: ≈2–3 part-time days, dominated by polish on the marquee selection UI. The OCR engine itself is **Apple Vision** (`VNRecognizeTextRequest`) — local, free, on-device, accurate. No new third-party dependencies. No new TCC permissions beyond Screen Recording (which we already have for meetings).

The feature is parallel to the meeting/dictation work — completely independent code path. Mode A (dictation) and meeting mode stay untouched.

---

## 2. What ships

### 2.1 User flow

1. User presses **⌥⌘O** (default; rebindable in Settings).
2. SolWhisper records the previously-focused app, then triggers a marquee selection (cursor → crosshair, full-screen overlay).
3. User drags a rectangle. Esc cancels.
4. Region is captured to PNG, fed through Vision OCR.
5. Recognized text post-processed per Settings (line-break handling, whitespace cleanup).
6. Text goes to clipboard. **Optionally** auto-pastes into the previously-focused app (off by default for a less invasive default).
7. Brief tray-icon flash + (optional) system sound to confirm.

If no text is detected: brief notification "No text found" — clipboard untouched.

### 2.2 Settings — new "Screen OCR" section

| Control | Default | Notes |
|---|---|---|
| **Hotkey** | unset (user picks) | Lives in the existing Hotkey settings section (recordable). Default to be discussed before ship. |
| **Remove line breaks** | Off (= keep) | Toggle: when on, wrapped lines within a paragraph are joined; paragraphs separated by blank-line gaps are preserved (heuristic in §6). |
| **Recognition speed** | Accurate | Picker: Fast / Accurate (Vision's two `recognitionLevel` modes) |
| **Languages** | Auto (system) | Multi-select; defaults to system languages |
| **Use language correction** | On | Maps to `VNRecognizeTextRequest.usesLanguageCorrection` |

**Decisions locked from user:**
- No success-sound toggle. Drop entirely.
- `PasteManager` not modified. The result bubble (§2.4) handles auto-paste via the existing `PasteManager.paste(text:into:)` call site — no signature changes.
- Default hotkey: TBD; ships unset so the user picks first run (or assigns one in Settings → Hotkey).

### 2.3 Tray menu addition

```
…
✂ Snip text from screen     (hotkey if set)
…
```

State variants:
- Idle: `Snip text from screen`
- During capture/OCR/bubble-visible: `Snipping…` (disabled — prevents double-trigger)

### 2.4 Snip-result bubble — the new piece (decided this round)

After OCR completes, a small floating panel appears showing the recognized text. Visually + behaviorally modeled on the existing live-transcript bubble (`TranscriptBubbleView` from `Sources/Overlay/RecordingOverlayView.swift`):

- **Look**: dark rounded rectangle (corner radius 18), `Color(white: 0.10, opacity: 0.94)`, soft shadow. Same width (460 pt) as the dictation transcript bubble for visual consistency. Height auto-fits the text up to 4 lines + scroll.
- **Position**: near the screen-region the user just snipped (above-center of the captured rect), with screen-edge fallback so it never spills off the visible frame.
- **Always-on-top**, non-activating panel — does not steal focus from the previously-focused app.

The bubble is the entire UI surface. Clipboard is set as soon as it appears, so manual ⌘V into any window works immediately.

**Dismissal — happens automatically on paste:**

The bubble disappears the moment the text has been pasted, by any of these signals (whichever fires first):

1. **User clicks the bubble** (or presses Return) → we fire `PasteManager.paste(text:into:previouslyFocusedApp)`, then dismiss with a fade-out.
2. **User presses ⌘V anywhere else** → we monitor `NSPasteboard.general.changeCount` for an *outgoing* read by detecting that another app's pasteboard activity has moved on; combined with a global ⌘V key monitor (passive `NSEvent.addGlobalMonitorForEvents`) that doesn't intercept, just observes. When ⌘V fires while our text is still on top of the clipboard, we dismiss. (No accessibility tap needed — the existing `NSEvent` monitor we already use for Esc in mode A is the same machinery.)
3. **User presses Esc** → dismiss without pasting (clipboard still has the text since we copied at step 0).
4. **8-second idle timeout** → fade out. The number is tunable in Settings (Sprint 9.6) but ships at 8 s.
5. **Click outside the bubble** → dismiss. Standard mac panel behavior.

**The user's specific request — "disappears once you paste it" — maps to (1) and (2).** Both fire reliably: (1) is unambiguous, and (2) covers the natural flow where the user reads the bubble, switches to the target app, and pastes.

The bubble's text is `.textSelection(.enabled)` so the user can also right-click → Copy a sub-range, or hand-edit before pasting. (Edit mode is a v0.6 idea — for v1 the text is read-only display.)

### 2.3 Tray menu addition

```
…
✂ Snip text from screen     ⌥⌘O
…
```

State variants are simpler than meeting mode — there are only two:
- Idle: `Snip text from screen`
- During capture/OCR: `Snipping…` (disabled)

Capture takes < 1 second on M-series, so most users will never see the disabled state.

---

## 3. Architecture

### 3.1 Directory tree (new)

```
Sources/
└── OCR/                              # ✚ NEW
    ├── ScreenSnipperController.swift # state machine: trigger → capture → OCR → bubble
    ├── ScreenCapture.swift           # wraps `screencapture -i -t png` invocation
    ├── TextRecognizer.swift          # Vision wrapper, returns [LineObservation]
    ├── OCRPostProcessor.swift        # line-break + whitespace handling, pure value-type
    └── SnipResultBubble.swift        # NSPanel + SwiftUI, modeled on TranscriptBubbleView

Sources/Settings/
└── OCRSettingsView.swift             # ✚ NEW (Screen OCR pane)

Sources/HotKey/
└── HotkeyManager.swift               # ↻ add `onSnipHotkeyPressed` callback +
                                      #   user-recordable hotkey slot (no default)

Sources/App/
└── AppDelegate.swift                 # ↻ wire snip menu item + hotkey + reuse PasteManager

Tests/SolWhisperTests/
└── OCRPostProcessorTests.swift       # ✚ NEW — pure-function tests
```

### 3.2 Component diagram

```
                  Hotkey ⌥⌘O                   Tray "Snip text from screen"
                       │                                        │
                       └──────────────┬─────────────────────────┘
                                      ▼
                       ┌──────────────────────────────┐
                       │  ScreenSnipperController     │ ← single instance, owned by AppDelegate
                       │  state: idle → capturing →   │
                       │         recognizing → done   │
                       └──┬───────────────────────────┘
                          │
                          ▼
            ┌─────────────────────┐
            │ ScreenCapture       │  spawns `/usr/sbin/screencapture -i -t png /tmp/sw-snip-XXX.png`
            │ (interactive PNG)   │  Esc cancels (no file written → bail silently)
            └──────────┬──────────┘
                       ▼
            ┌─────────────────────┐
            │ TextRecognizer      │  VNRecognizeTextRequest on the PNG
            │ (Apple Vision)      │  returns [LineObservation { text, boundingBox, confidence }]
            └──────────┬──────────┘
                       ▼
            ┌─────────────────────┐
            │ OCRPostProcessor    │  pure: settings + observations → final string
            │ - line break mode   │  ┌──────────────────────────┐
            │ - whitespace fix    │  │ Keep      → join "\n"    │
            │ - paragraph detect  │  │ Remove    → join " "     │
            │   (Y-gap heuristic) │  │           paragraphs kept │
            └──────────┬──────────┘  └──────────────────────────┘
                       ▼
        ┌────────────────────────────────┐
        │ NSPasteboard.general           │ atomic write (immediately, on bubble appear)
        └─────┬──────────────────────────┘
              │
              ▼
        ┌────────────────────────────────┐
        │ SnipResultBubble (NSPanel)     │ floating, non-activating, modeled on
        │  ─ shows OCR text              │ TranscriptBubbleView (same look + corner radius)
        │  ─ Click / ↩ → paste + dismiss │
        │  ─ Esc → dismiss only          │
        │  ─ ⌘V detected → dismiss       │ via existing global NSEvent monitor
        │  ─ 8-s idle timeout → dismiss  │
        └─────┬──────────────────────────┘
              │ (paste action, only if user picks "paste"
              │  via click / ↩ / observed ⌘V into another app)
              ▼
        ┌────────────────────────────────┐
        │ PasteManager.paste(text:into:) │ existing dictation paste path — unchanged
        └────────────────────────────────┘
```

### 3.3 Data flow

```swift
struct LineObservation: Sendable {
    let text: String                   // top candidate
    let confidence: Float              // 0.0 – 1.0
    let boundingBox: CGRect            // normalized, Vision coordinates
}

struct OCRSettings: Sendable {
    let lineBreakMode: LineBreakMode   // .keep / .remove
    let recognitionLevel: VNRequestTextRecognitionLevel
    let usesLanguageCorrection: Bool
    let recognitionLanguages: [String]
}

enum LineBreakMode { case keep, remove }
```

`OCRPostProcessor` is pure: takes `OCRSettings` + `[LineObservation]` and returns a `String`. Trivially testable. The line-break handling logic — see §6.

---

## 4. Implementation plan

### Sprint 9.1 — ScreenCapture wrapper (3–4 hrs)

`ScreenCapture.swift`:

```swift
@MainActor
enum ScreenCapture {
    /// Spawns `/usr/sbin/screencapture -i -t png <tempURL>` and awaits
    /// completion. Returns the PNG URL on success, nil if the user pressed Esc
    /// (no file written) or the helper exited non-zero.
    static func interactive() async -> URL? {
        let url = makeTempURL()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-t", "png", url.path]
        return await withCheckedContinuation { cont in
            task.terminationHandler = { _ in
                let exists = FileManager.default.fileExists(atPath: url.path)
                cont.resume(returning: exists ? url : nil)
            }
            do { try task.run() } catch { cont.resume(returning: nil) }
        }
    }
}
```

Why `screencapture -i` and not a custom NSWindow marquee:
- macOS's tool is polished — handles multi-monitor, retina scaling, all the modifier keys (Space to drag selection, Shift to constrain, Esc to cancel).
- Zero risk of building a janky in-house marquee that breaks on edge cases.
- Cost: brief flash where SolWhisper isn't focused, and the user sees the system shutter sound (we mute via `-x` if the user toggles "Silent capture").

### Sprint 9.2 — TextRecognizer (2 hrs)

`TextRecognizer.swift`:

```swift
struct TextRecognizer {
    let settings: OCRSettings

    func recognize(_ pngURL: URL) async throws -> [LineObservation] {
        guard let data = try? Data(contentsOf: pngURL),
              let cgImage = NSBitmapImageRep(data: data)?.cgImage else {
            throw OCRError.imageLoadFailed
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = settings.recognitionLevel
        request.usesLanguageCorrection = settings.usesLanguageCorrection
        request.recognitionLanguages = settings.recognitionLanguages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        return try await Task.detached(priority: .userInitiated) {
            try handler.perform([request])
            return (request.results ?? []).compactMap { obs in
                guard let candidate = obs.topCandidates(1).first else { return nil }
                return LineObservation(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    boundingBox: obs.boundingBox
                )
            }
        }.value
    }
}
```

Vision specifics worth pinning:
- `recognitionLevel = .accurate` ≈ 50–200 ms on M-series for a screen-sized region.
- `revision = VNRecognizeTextRequestRevision3` (default on macOS 13+) — best accuracy.
- Language list: the Vision-supported set per macOS version (English-only on Catalina, full set on Ventura+). Per TextSniper's research, this matches the Vision capability matrix exactly. Default `recognitionLanguages = []` means Vision auto-detects.
- Returns observations in **bottom-up Y order** (Vision uses Cartesian coordinates with origin at lower-left). We normalize this in the post-processor.

### Sprint 9.3 — OCRPostProcessor (3–4 hrs incl. tests)

This is where the user's "keep or remove line breaks" toggle lives.

```swift
enum OCRPostProcessor {

    /// Normalizes Vision observations into a single user-facing string.
    static func process(_ observations: [LineObservation],
                        mode: LineBreakMode) -> String {
        // 1. Sort top-to-bottom (Vision Y-axis is inverted from screen).
        let sorted = observations.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }

        switch mode {
        case .keep:
            return sorted.map(\.text).joined(separator: "\n")
        case .remove:
            return joinAcrossWraps(sorted)
        }
    }

    /// Heuristic paragraph detection — preserves blank-line breaks even
    /// when "remove line breaks" is on. A "paragraph break" is detected
    /// when the vertical gap between two consecutive lines exceeds 1.6×
    /// the median line height.
    private static func joinAcrossWraps(_ lines: [LineObservation]) -> String {
        guard !lines.isEmpty else { return "" }
        let heights = lines.map { $0.boundingBox.height }
        let median = heights.sorted()[heights.count / 2]
        let paragraphGap = median * 1.6

        var pieces: [String] = []
        var paragraph: [String] = [lines[0].text]
        for i in 1..<lines.count {
            let prev = lines[i - 1]
            let cur = lines[i]
            let gap = prev.boundingBox.minY - cur.boundingBox.maxY
            if gap > paragraphGap {
                pieces.append(paragraph.joined(separator: " "))
                paragraph = [cur.text]
            } else {
                paragraph.append(cur.text)
            }
        }
        pieces.append(paragraph.joined(separator: " "))
        return pieces.joined(separator: "\n\n")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

Tests cover:
- Empty input → empty string
- Single line keep + remove
- Two-line wrapped paragraph in remove mode → joined with single space
- Two distinct paragraphs (large Y gap) in remove mode → still separated by `\n\n`
- All-keep mode produces verbatim line breaks
- Whitespace collapse (multiple spaces → one)

### Sprint 9.4 — ScreenSnipperController (4 hrs)

State machine + orchestration. Owns the focused-app snapshot so paste-into works.

```swift
@MainActor
final class ScreenSnipperController {
    enum State { case idle, capturing, recognizing, completing }
    @Published private(set) var state: State = .idle

    private var pasteTarget: NSRunningApplication?

    func snip() {
        guard state == .idle else { return }
        // Snapshot the previously-focused app (mode A pattern).
        pasteTarget = NSWorkspace.shared.frontmostApplication
        Task { await run() }
    }

    private func run() async {
        state = .capturing
        guard let pngURL = await ScreenCapture.interactive() else {
            state = .idle; return         // user cancelled
        }
        defer { try? FileManager.default.removeItem(at: pngURL) }

        state = .recognizing
        let settings = OCRSettings.fromUserDefaults()
        let recognizer = TextRecognizer(settings: settings)
        let observations: [LineObservation]
        do {
            observations = try await recognizer.recognize(pngURL)
        } catch {
            state = .idle
            return     // log + silent fail
        }

        let text = OCRPostProcessor.process(observations,
                                            mode: settings.lineBreakMode)
        guard !text.isEmpty else {
            state = .idle
            await notifyNoText()
            return
        }

        state = .completing
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if UserDefaults.standard.bool(forKey: "ocrAutoPaste"),
           let target = pasteTarget {
            await PasteManager.paste(text: text, into: target)
        }
        await notifySuccess(charactersCopied: text.count)
        state = .idle
    }
}
```

### Sprint 9.5 — Hotkey + tray menu integration (2 hrs)

`HotkeyManager.swift` already supports register-key-with-modifiers. Add:

```swift
var onSnipHotkeyPressed: (() -> Void)?
```

`AppDelegate`:

```swift
hotkeyManager.onSnipHotkeyPressed = { [weak self] in
    self?.snipScreenText()
}

@objc func snipScreenText() {
    snipperController.snip()
}
```

Tray menu insertion next to "Upload audio file…":

```swift
let snip = NSMenuItem(title: "Snip text from screen…",
                      action: #selector(snipScreenText),
                      keyEquivalent: "o")
snip.keyEquivalentModifierMask = [.option, .command]
snip.image = trayIcon("rectangle.dashed.and.paperclip")
menu.addItem(snip)
```

### Sprint 9.6 — Settings UI (2–3 hrs)

`OCRSettingsView.swift`:

```swift
struct OCRSettingsView: View {
    @AppStorage("ocrLineBreakMode") private var lineBreakMode = "keep"
    @AppStorage("ocrRecognitionLevel") private var level = "accurate"
    @AppStorage("ocrUseLangCorrection") private var langCorrect = true
    @AppStorage("ocrAutoPaste") private var autoPaste = false
    @AppStorage("ocrPlaySound") private var playSound = false

    var body: some View {
        Form {
            Section("Result") {
                Picker("Line breaks", selection: $lineBreakMode) {
                    Text("Keep").tag("keep")
                    Text("Remove (preserves paragraphs)").tag("remove")
                }
                Picker("Recognition speed", selection: $level) {
                    Text("Accurate (default)").tag("accurate")
                    Text("Fast").tag("fast")
                }
                Toggle("Use language correction", isOn: $langCorrect)
            }
            Section("After OCR") {
                Toggle("Auto-paste into focused app", isOn: $autoPaste)
                Toggle("Play sound on success", isOn: $playSound)
            }
            Section("Hotkey") {
                Text("Default: ⌥⌘O — change in the Hotkey tab.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Screen OCR")
    }
}
```

Add `.ocr` case to `SettingsSection` enum, route in `SettingsView`'s switch.

### Sprint 9.7 — Tests + QA (2 hrs)

Per existing testing posture (`Tests/SolWhisperTests/`):

```swift
final class OCRPostProcessorTests: XCTestCase {
    // boundingBox uses Vision-style Cartesian: origin = lower-left,
    // larger Y = higher on screen.
    func makeLine(_ text: String, top: CGFloat, height: CGFloat = 0.04)
        -> LineObservation { ... }

    func testKeepMode() { /* 3 lines → joined with \n */ }
    func testRemoveModeJoinsWraps() { /* 3 close lines → 1 sentence */ }
    func testRemoveModeKeepsParagraphsAcrossLargeGaps() { /* 2 groups → \n\n */ }
    func testEmptyInput() { ... }
    func testWhitespaceCollapse() { /* multiple spaces normalized */ }
    func testSortIsTopToBottom() { /* unsorted input → sorted output */ }
}
```

No integration test for actual Vision recognition — too platform-dependent for a fast unit suite. Manual demo checks (§5) cover the end-to-end.

---

## 5. Demo criteria

The user can sign off when:

- [ ] Press ⌥⌘O → cursor changes to crosshair → drag a rectangle over a paragraph in any app → recognized text on clipboard within 1 second.
- [ ] **Line break: Keep** → snip a multi-paragraph article → result preserves both line breaks within paragraphs and blank lines between them.
- [ ] **Line break: Remove** → same article → each paragraph becomes a single line; paragraphs separated by blank line.
- [ ] **Auto-paste: On** → snip → text pastes into the previously-focused app immediately (no manual ⌘V).
- [ ] **Auto-paste: Off** (default) → snip → user pastes manually with ⌘V; text matches.
- [ ] Press ⌥⌘O, press Esc during capture → no error, clipboard unchanged.
- [ ] Snip an empty/blank region → "No text found" notification, clipboard unchanged.
- [ ] Snip works on multi-monitor setups, on retina + non-retina displays.
- [ ] Snip works while a meeting is recording (no audio interruption).

---

## 6. Risks and unknowns

| # | Risk | Mitigation |
|---|---|---|
| 1 | `screencapture -i` shutter sound annoys users in calls | Default off; "Silent capture" toggle in Settings (uses `-x` flag) |
| 2 | macOS UI temporarily steals focus during marquee | Snapshot pasteTarget BEFORE invoking, restore via PasteManager |
| 3 | Vision OCR confidence on dense / small text is poor | Default `recognitionLevel = .accurate`; expose Fast/Accurate toggle |
| 4 | User wants different OCR engine (Tesseract, etc.) | Out of scope. Vision covers 99%; protocol-ize if demand emerges |
| 5 | Capturing a region that contains protected content (e.g. DRM video) returns black pixels | macOS's expected behavior. Document in Settings footer ("System content protection may blank some captures") |
| 6 | Multi-language docs → wrong recognition language | "Auto" default lets Vision pick; user can pin a list explicitly |
| 7 | Hotkey conflict with built-in macOS screenshot shortcut (⌘⇧3/4) | Default to ⌥⌘O (no conflict); user-rebindable |
| 8 | Power-user wants OCR-then-LLM cleanup (typo fix, summarize) | Out of scope v1. Easy to add via existing `OpenRouterLLMClient` later |

---

## 7. What stays the same

These files **must not change**:

```
Sources/Audio/AudioEngine.swift
Sources/Transcription/AppleSpeechClient.swift
Sources/Transcription/DeepgramClient.swift
Sources/Transcription/WhisperKitClient.swift
Sources/Meeting/*
Sources/Overlay/*
Sources/Paste/PasteManager.swift   ← reused, but no signature changes
```

This is a green-field feature. Mode A, file import, meeting recording all keep their existing code paths.

---

## 8. Calendar

| Task | Hours | Day |
|---|---:|---|
| ScreenCapture wrapper + manual smoke test | 3 | 1 |
| TextRecognizer (Vision wrapper) | 2 | 1 |
| OCRPostProcessor + 6 unit tests | 4 | 1 |
| ScreenSnipperController state machine | 3 | 2 |
| **SnipResultBubble** (NSPanel + view + auto-dismiss machinery) | 4 | 2 |
| Hotkey + tray menu integration | 2 | 3 |
| OCRSettingsView (incl. "Remove line breaks" toggle) | 2 | 3 |
| Manual demo + polish | 2 | 3 |
| **Total** | **~22 hours** | **~3 days** |

---

## 9. Decisions to lock in

| # | Decision | Resolved |
|---|---|---|
| 1 | Default hotkey | **TBD — ships unset**, user picks via Settings → Hotkey. Discussion deferred. |
| 2 | After-OCR UX | **Snip-result bubble shows the text** (modeled on dictation transcript bubble). Clipboard set on appear. Bubble dismisses on click/↩/⌘V/Esc/8 s timeout. |
| 3 | Line-break toggle | **Setting present** — "Remove line breaks" (off by default = keep verbatim). Paragraph-preserving heuristic when on. |
| 4 | Default recognition level | Accurate |
| 5 | Sound | **Cut.** No sound toggle, no notification audio. |
| 6 | `PasteManager` modifications | **None.** Bubble's "paste" action calls existing `PasteManager.paste(text:into:)` site only. |
| 7 | Naming | "Screen OCR" (Settings section), "Snip text from screen" (tray + menu) |
| 8 | Tray icon | `rectangle.dashed.and.paperclip` |
| 9 | Settings section position | Sidebar — between `.integrations` and `.vocabulary` |
| 10 | Sprint slot | v0.5.0 (after v0.4 GA + notarization), or v0.4.0-alpha.3 if user wants it sooner |

Confirm or override and I'll execute. The whole feature is independent of the ongoing meeting/notarization work — could go in a parallel branch if you want it sooner.

---

## 10. v0.6+ ideas

Out of scope for the first cut, noted so future-me doesn't reinvent:

- **OCR + LLM cleanup**: optional pass-through that fixes OCR errors via Claude / Ollama. One toggle in Settings.
- **OCR history**: small ring buffer of last 10 snips, viewable from the tray. Useful for "I copied two things in a row, need the previous".
- **Append mode**: shift-snip to append to clipboard instead of replacing.
- **Keyboard navigation through observations**: instead of a single string output, let the user accept individual lines via a popover. Useful for messy slide decks.
- **QR / barcode** support — Vision has `VNDetectBarcodesRequest`. TextSniper does this; we should too eventually.
- **Custom regions** — recall the last N rectangles, snap-back to a frequently-used area (e.g. always the top-right of a Zoom window).

---

*End of plan. Net change to existing app: 1 enum case in `SettingsSection`, 1 callback on `HotkeyManager`, 1 menu item in `AppDelegate`, 1 reuse of `PasteManager`. Everything else lives under `Sources/OCR/`.*

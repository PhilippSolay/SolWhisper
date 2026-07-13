import AppKit
import AVFoundation
import Combine
import SwiftUI
import Sparkle

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private var overlayWindowController: OverlayWindowController?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var hotkeyManager: HotkeyManager?
    private var toggleMenuItem: NSMenuItem?
    private var updaterController: SPUStandardUpdaterController!

    let transcriptionController = TranscriptionController()
    private(set) var secretsStore: SecretsStore!
    private(set) lazy var meetingStore: MeetingStore = {
        let s = MeetingStore()
        try? s.loadAll()
        return s
    }()
    private var transcriptsWindowController: TranscriptsWindowController?
    /// Serial queue for file imports — every import entry point funnels here
    /// and progress renders inline in the Transcripts detail area (no windows).
    private(set) lazy var importQueue: ImportQueue = {
        let queue = ImportQueue(store: meetingStore)
        queue.onActivity = { [weak self] in self?.openTranscripts() }
        queue.onBatchFinished = { [weak self] report in self?.presentImportReport(report) }
        return queue
    }()
    private(set) lazy var meetingController: MeetingController = {
        let c = MeetingController(store: meetingStore)
        // Open the Transcripts window with this meeting selected the moment
        // post-processing starts (stitching). The user immediately sees the
        // pipeline progress indicator instead of a generic "processing" pill.
        c.onProcessingStarted = { [weak self] meetingID in
            self?.openTranscriptsAndSelect(meetingID)
        }
        c.onProcessed = { [weak self] _ in
            // Drive any queued orphan recoveries.
            self?.startNextRecoveryIfIdle()
        }
        return c
    }()
    private(set) lazy var snipperController = ScreenSnipperController()
    private(set) lazy var translationController = TranslationController()
    let voiceTranslateController = VoiceTranslateController()
    /// True while the active recording session should translate its transcript
    /// (voice-translate mode) rather than paste it verbatim.
    private var isVoiceTranslateActive = false
    /// Holds the translate bubble presented after a voice-translate session so
    /// it isn't deallocated while on screen.
    private var voiceTranslateBubble: TranslateResultBubble?
    private var meetingMenuItem: NSMenuItem?
    private var audioMenuItem: NSMenuItem?
    private var audioSubmenuRef: NSMenu?
    private var meetingPillController: OverlayWindowController?
    private var meetingStateCancellable: AnyCancellable?
    private var meetingStatusObserver: NSObjectProtocol?
    private var escMonitor: Any?

    /// Continuously updated — always the last app that had focus before SolWhisper.
    private var pasteTarget: NSRunningApplication?
    /// Locked-in at startRecording() — the app that should receive the paste.
    private var recordingTarget: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Under XCTest the unit-test bundle launches this app as its test host.
        // Skip all runtime setup — status bar, permission prompts, windows,
        // one-shot migrations — so the suite runs headless and never triggers
        // TCC permission prompts (mic / speech / accessibility). Individual
        // one-shots like MeetingAudioCompaction already guard this the same way.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        // Default hotkeys — all on `⌃⌥⌘` so we don't fight macOS Spotlight
        // (⌘Space) or any common app shortcuts. Mask 11 = Ctrl + Opt + Cmd.
        // Key codes (US ANSI): R=15, M=46, P=35, O=31, T=17.
        UserDefaults.standard.register(defaults: [
            "enableLLMPolish":    true,
            "audioEnhancement":   true,
            "hotkeyKeyCode":            15,   // R — Transcription Start/Stop
            "hotkeyModifierMask":       11,   // ⌃⌥⌘
            "pauseHotkeyKeyCode":       35,   // P — Pause/Resume
            "pauseHotkeyModifierMask":  11,   // ⌃⌥⌘
            "meetingHotkeyKeyCode":     46,   // M — Meeting Start/Stop
            "meetingHotkeyModifierMask": 11,  // ⌃⌥⌘
            "snipHotkeyKeyCode":        31,   // O — Screen capture OCR
            "snipHotkeyModifierMask":   11,   // ⌃⌥⌘
            "transcriptsHotkeyKeyCode":      17,  // T — Open Transcripts
            "transcriptsHotkeyModifierMask": 11,  // ⌃⌥⌘
            "translateHotkeyKeyCode":        37,  // L — Translate from screen
            "translateHotkeyModifierMask":   11,  // ⌃⌥⌘
            "translateTargetLanguage":       "en",
            // Voice-translate (speak → transcribe → translate → paste). Hotkey
            // ships unset (user assigns it in Settings → Hotkey). It uses the
            // shared translation engine (`TranslationEngineKind.current`), so
            // there's no VT-specific engine default — only the target language.
            "voiceTranslateTargetLanguage":  "en",
            // Translate engine + routing — registered alongside the existing
            // role defaults so a fresh install has the same fallback shape
            // as dictation / cleanup / summary. Engine default left as the
            // empty string so `TranslationEngineKind.current` keeps deriving
            // it from OS capability (.apple on 15+, .llm below).
            "translationLLMProvider":        "openrouter",
            "openRouterModel":    "anthropic/claude-3-5-haiku",
            "whisperKitModel":    WhisperKitClient.defaultModel,
            "meetingsWhisperKitModel": WhisperKitClient.defaultModel,
            "customVocabulary":   "[]",
            "polishRemoveFiller":   true,
            "polishFixPunctuation": true,
            "polishFixGrammar":     false,
            "showLiveTranscript":   true,
            // Meeting auto-pipeline toggles. These MUST match MeetingSettingsView's
            // @AppStorage defaults, because the pipeline reads them via
            // UserDefaults.bool(forKey:) which is `false` when unregistered.
            // Auto-summarize in particular showed ON in Settings but silently
            // never ran on a fresh install until it was registered here.
            "meetingsAutoSummarize":      true,
            "meetingsAutoCleanTranscript": true,
            "meetingsAudioDucking":       true,
            "meetingsClippingDetect":     true,
            "meetingsRecordingDisclosure": true,
            "meetingsChunkSeconds":       30,
        ])

        migrateLegacyHotkeyDefaultsIfNeeded()

        // v0.7.3 and earlier offered "large-v3-turbo" in the WhisperKit
        // picker — an ID that never existed upstream, so downloads and
        // meeting transcription failed with "No models found". Remap saved
        // selections to the real turbo ID ("large-v3-v20240930").
        WhisperKitClient.migrateLegacyModelIDs()

        // Pre-alpha.4 default of "pause" sent the system Play/Pause media key
        // on every dictation start, which surprised users by also pausing
        // Spotify/Music/video tabs. New default is "nothing"; existing installs
        // with the legacy "pause" value get migrated once.
        if !UserDefaults.standard.bool(forKey: "playbackOnRecordMigratedFromPause") {
            if UserDefaults.standard.string(forKey: "audioPlaybackOnRecord") == "pause" {
                UserDefaults.standard.set("nothing", forKey: "audioPlaybackOnRecord")
            }
            UserDefaults.standard.set(true, forKey: "playbackOnRecordMigratedFromPause")
        }

        // Recording hotkey is the primary feature — if its keyCode has been
        // cleared (= 0) the global listener can't fire and the menu shows
        // nothing. Restore the default ⌃⌥⌘R every launch when the keyCode
        // is missing; users who explicitly cleared it can clear again
        // (they get one default restoration, not a permanent gag).
        if UserDefaults.standard.integer(forKey: "hotkeyKeyCode") == 0 {
            UserDefaults.standard.set(15, forKey: "hotkeyKeyCode")        // R
            UserDefaults.standard.set(11, forKey: "hotkeyModifierMask")   // ⌃⌥⌘
            DebugLog.shared.log(icon: "⌨️", label: "Restored recording hotkey",
                                value: "⌃⌥⌘R (was unset)")
        }
        // Migrate any previously stored invalid model IDs
        let storedModel = UserDefaults.standard.string(forKey: "openRouterModel") ?? ""
        let invalidModels = ["anthropic/claude-haiku-4-5-20251001", "anthropic/claude-haiku-4-5", "anthropic/claude-sonnet-4-6"]
        if invalidModels.contains(storedModel) {
            UserDefaults.standard.set("anthropic/claude-3-5-haiku", forKey: "openRouterModel")
        }

        // Sprint 0: move openRouterApiKey from UserDefaults → Keychain on first launch.
        // Must run BEFORE seedLocalSecrets() and BEFORE SecretsStore() reads from Keychain.
        SecretsStore.migrateFromUserDefaultsIfNeeded()
        seedLocalSecrets()
        secretsStore = SecretsStore()
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        PasteManager.requestAccessibilityIfNeeded()
        AppleSpeechClient.requestAuthorization { _ in }
        checkPermissionsHealth()
        trackActiveApp()
        setupStatusBar()
        setupHotkey()

        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            openOnboarding()
        }

        scanForOrphanMeetingsOnLaunch()
        bindMeetingPillToController()

        // One-shot voice-print backfill. The previous embedder hung on long
        // files, leaving every saved profile as name-only. The new
        // streaming resampler unsticks capture — this pass retroactively
        // captures embeddings for any profile with a known source meeting,
        // then re-runs the voice matcher across recent meetings.
        // Idempotent and runs in the background.
        if #available(macOS 14.0, *) {
            VoiceProfileBackfill.runAtLaunch(meetingStore: meetingStore,
                                              profileStore: VoiceProfileStore.shared)
        }

        // Convert any pre-alpha.4 legacy routing state into ConfiguredModels.
        // One-shot, gated by `modelStoreLegacyMigrationDone`.
        LegacyModelMigration.migrateIfNeeded()

        // Eagerly initialize persistent stores so the Home tab's stats are
        // populated on first render. Without this, the singletons lazy-init
        // when the view first observes them — which is fine functionally
        // but can flash empty values for one render cycle.
        _ = DictationHistoryStore.shared

        // Additive clipboard's clear-on-paste tap (no-op if disabled / no AX).
        AdditiveClipboard.shared.startClearOnPasteIfNeeded()

        // One-shot retention sweep — deletes meetings + dictation history
        // older than the user's "Keep recordings for" policy.
        RetentionSweep.run(meetingStore: meetingStore)

        // One-shot: re-encode any legacy float32 WAV recordings to mono AAC
        // .m4a and delete the WAVs (gated by `meetingAudioCompactionV1Done`).
        MeetingAudioCompaction.runIfNeeded(meetingStore: meetingStore)

        // Refresh launch-on-login mirror state (in case user toggled it via
        // System Settings while the app was closed).
        LaunchAtLogin.shared.refresh()

        // Surface a friendly error in the overlay if the chosen mic doesn't
        // deliver any audio within ~2 seconds of pressing record. Catches
        // routing failures (HAL device-set silently failed), revoked mic
        // permission mid-session, and physically muted hardware.
        transcriptionController.onAudioFailure = { [weak self] message in
            Task { @MainActor in
                self?.handleAudioFailure(message: message)
            }
        }

        // Auto-paste couldn't insert (no Accessibility) — the text is on the
        // clipboard. Surface a visible notice instead of a silent no-op, which
        // was the top "I dictated and nothing happened" first-run failure.
        PasteManager.onClipboardFallback = { [weak self] in
            self?.overlayWindowController?.showAudioError(
                "On your clipboard — press ⌘V. Turn on SolWhisper in System Settings → Privacy & Security → Accessibility to auto-paste next time."
            ) { [weak self] in
                self?.overlayWindowController?.hideOverlay()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort clean teardown on quit. If a dictation is mid-flight, tear
        // it down so the audio engine/temp file is flushed and closed rather
        // than left half-written. A dictation the user never Stopped is
        // discarded, not saved (product decision — a half-finished take isn't
        // worth persisting to history). Meetings are chunk-written continuously
        // and recovered on next launch (see CrashRecovery), so they need no action.
        if transcriptionController.isRecording {
            transcriptionController.cancel()
        }
        ErrorLogger.shared.sweepOldLogs()
    }

    /// Shows the error banner and tears down the recording session after
    /// the banner has been visible long enough to read.
    @MainActor
    private func handleAudioFailure(message: String) {
        removeEscMonitor()
        updateStatusBarIcon(recording: false)
        AudioFeedback.play(.stop)
        PlaybackController.recordingDidEnd()
        recordingStartedAt = nil
        // The overlay stays up for the duration; onDismiss hides it cleanly.
        overlayWindowController?.showAudioError(message) { [weak self] in
            self?.overlayWindowController?.hideOverlay()
        }
    }

    /// Spawns the pill (in `.meeting` mode) when MeetingController enters
    /// `.recording` or `.paused`, and tears it down when the controller goes
    /// back to `.idle`. Updates the pill's phase to mirror the controller.
    /// Also bridges meeting audio levels into TranscriptionController.audioLevel
    /// so the pill's existing waveform machinery picks up the pulse.
    private func bindMeetingPillToController() {
        meetingStateCancellable = meetingController.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleMeetingState(state)
            }

        // Mic level pulse during meetings — bridges into TranscriptionController
        // so the pill's existing waveform machinery picks up the energy.
        // We prefer real per-bin spectrum from MeetingController if available,
        // and fall back to a flat-pulse based on micLevel.
        meetingController.$micLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                guard let self else { return }
                guard self.meetingController.isRecording else { return }
                self.transcriptionController.audioLevel = level
                // Use real spectrum bins if MeetingAudioEngine has computed
                // them; otherwise pulse uniformly.
                let bins = self.meetingController.spectrumBins
                if bins.contains(where: { $0 > 0.0001 }) {
                    self.transcriptionController.spectrumBins = bins
                } else {
                    self.transcriptionController.spectrumBins =
                        [Float](repeating: level, count: AudioEngine.fftBinCount)
                }
            }
            .store(in: &meetingLevelSubscriptions)

        // Clipping → pill red ring.
        meetingController.$isClipping
            .receive(on: DispatchQueue.main)
            .sink { [weak self] clip in
                self?.meetingPillController?.phaseState.isClipping = clip
            }
            .store(in: &meetingLevelSubscriptions)
    }

    private var meetingLevelSubscriptions: Set<AnyCancellable> = []

    private func handleMeetingState(_ state: MeetingController.State) {
        switch state {
        case .recording:
            ensureMeetingPill()
            meetingPillController?.phaseState.phase = .listening
        case .paused:
            ensureMeetingPill()
            meetingPillController?.phaseState.phase = .paused
        case .stopping, .processing:
            // Hide the pill instead of showing the dictation-style processing
            // dots. The Transcripts window has been opened with this meeting
            // selected (see onProcessingStarted) and shows a phase-aware
            // pipeline indicator — much more informative than a vague pill.
            meetingPillController?.forceHide()
            meetingPillController = nil
        case .idle:
            meetingPillController?.forceHide()
            meetingPillController = nil
        case .starting:
            ensureMeetingPill()
        }
    }

    private func ensureMeetingPill() {
        if meetingPillController != nil { return }
        let pill = OverlayWindowController(
            transcriptionController: transcriptionController,
            onStop:   { [weak self] in self?.meetingController.stop()  },
            onCancel: { [weak self] in self?.meetingController.pause() },
            onPause:  { [weak self] in self?.toggleMeetingPause()       },
            // Meetings don't drive live partials — and any stale text from a
            // prior dictation would flash up below the meeting pill.
            showsLiveTranscript: false
        )
        pill.phaseState.mode = .meeting
        meetingPillController = pill
        pill.showOverlay()
    }

    private func toggleMeetingPause() {
        switch meetingController.state {
        case .recording: meetingController.pause()
        case .paused:    meetingController.resume()
        default: break
        }
    }

    /// Sprint 4a — if the previous run left orphan chunks (force-quit, crash),
    /// surface a recovery dialog. The user can recover (process chunks into a
    /// real meeting) or discard.
    private func scanForOrphanMeetingsOnLaunch() {
        reclaimInterruptedImportsOnLaunch()
        let orphans = CrashRecovery.scan(in: meetingStore)
        guard !orphans.isEmpty else { return }
        // Defer slightly so the dialog isn't competing with the missing-permissions
        // alert (also on a 1.5s delay).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            let toRecover = CrashRecovery.presentDialogIfNeeded(orphans: orphans)
            // Recover the first one immediately. If the user picked multiple,
            // queue subsequent recoveries via onProcessed.
            self.queueRecovery(toRecover)
        }
    }

    /// Re-runs imports interrupted (crash/quit) before they finished
    /// transcribing. The copied `audio.<ext>` is complete, so we re-enqueue it
    /// and trash the blank shell meeting — otherwise it sits in the list
    /// forever with no transcript and no way to finish.
    private func reclaimInterruptedImportsOnLaunch() {
        let interrupted = CrashRecovery.interruptedImports(in: meetingStore)
        guard !interrupted.isEmpty else { return }
        let fm = FileManager.default
        var reenqueue: [URL] = []
        for item in interrupted {
            // Move the audio OUT of the meeting folder before deleting the
            // shell — ImportQueue copies the source lazily when it processes
            // the item, so the file must survive the delete below.
            let staged = fm.temporaryDirectory
                .appendingPathComponent("solwhisper-resumed-import-\(item.meeting.id.uuidString)-\(item.audioURL.lastPathComponent)")
            try? fm.removeItem(at: staged)
            do {
                try fm.moveItem(at: item.audioURL, to: staged)
            } catch {
                DebugLog.shared.log(icon: "📥", label: "Import resume skipped",
                                    value: "couldn't stage \(item.audioURL.lastPathComponent): \(error)", ok: false)
                continue
            }
            reenqueue.append(staged)
            try? meetingStore.delete(item.meeting)
            DebugLog.shared.log(icon: "📥", label: "Resuming interrupted import",
                                value: item.audioURL.lastPathComponent)
        }
        if !reenqueue.isEmpty { _ = importQueue.enqueue(reenqueue) }
    }

    /// Recovers orphans one at a time. Each recovery's `onProcessed` callback
    /// kicks the next item; if the queue empties, the controller goes idle.
    private var pendingRecoveries: [CrashRecovery.OrphanSession] = []
    private func queueRecovery(_ orphans: [CrashRecovery.OrphanSession]) {
        guard !orphans.isEmpty else { return }
        pendingRecoveries.append(contentsOf: orphans)
        startNextRecoveryIfIdle()
    }

    private func startNextRecoveryIfIdle() {
        guard case .idle = meetingController.state, !pendingRecoveries.isEmpty else { return }
        let next = pendingRecoveries.removeFirst()
        meetingController.recover(orphan: next.meeting)
    }

    /// Observe every app activation and remember the last non-SolWhisper app.
    private func trackActiveApp() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.pasteTarget = app
        }
    }

    /// Check all critical permissions and warn if any are missing
    private func checkPermissionsHealth() {
        var missing: [String] = []

        // Microphone
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus != .authorized { missing.append("Microphone") }

        // Speech Recognition
        let speechStatus = AppleSpeechClient.authorizationStatus
        if speechStatus != .authorized { missing.append("Speech Recognition") }

        // Accessibility (for paste)
        if !PasteManager.hasAccessibility { missing.append("Accessibility") }

        if !missing.isEmpty {
            let list = missing.joined(separator: ", ")
            DebugLog.shared.log(icon: "⚠️", label: "Missing permissions", value: list, ok: false)

            // Non-blocking nudge via UNUserNotificationCenter (see
            // PermissionsNotifier). A modal NSAlert is intentionally avoided —
            // runModal() starves Swift concurrency during launch and would
            // deadlock the VoiceProfileBackfill store write. Its "Open Settings"
            // action deep-links to Privacy & Security (unlike the old
            // NSUserNotification, whose button no longer works on modern macOS).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                PermissionsNotifier.shared.notifyMissing(list)
            }
        } else {
            DebugLog.shared.log(icon: "✅", label: "All permissions granted")
        }
    }

    /// Seeds secrets from Resources/local-secrets.json (gitignored, never committed).
    /// Safe to call repeatedly — only writes if the destination is empty.
    ///
    /// `openRouterApiKey` is routed to Keychain (Sprint 0); other keys go to UserDefaults
    /// for now and will move to Keychain as their owning sprints rebuild them.
    private func seedLocalSecrets() {
        guard let url = Bundle.main.url(forResource: "local-secrets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let secrets = try? JSONDecoder().decode([String: String].self, from: data) else { return }

        // Route every Keychain-backed secret to the Keychain, not just
        // openRouter — otherwise a seeded key (e.g. Deepgram) lands in
        // plaintext UserDefaults. Sourced from the migration list so new
        // secrets are covered automatically.
        let keychainKeys = Set(SecretsStore.Keys.migratable)

        for (key, value) in secrets where !value.isEmpty {
            if keychainKeys.contains(key) {
                let existing = (try? KeychainStore.string(forKey: key)) ?? ""
                if existing.isEmpty {
                    try? KeychainStore.set(value, forKey: key)
                }
            } else if (UserDefaults.standard.string(forKey: key) ?? "").isEmpty {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let icon = NSImage(named: "MenuBarIcon") {
                icon.isTemplate = true
                icon.size = NSSize(width: 24, height: 18)
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "SolWhisper")
            }
        }

        let recKE = menuKeyEquivalent(
            keyCode: UserDefaults.standard.integer(forKey: "hotkeyKeyCode"),
            modifierMask: UserDefaults.standard.integer(forKey: "hotkeyModifierMask")
        )
        let item = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording),
                               keyEquivalent: recKE.key)
        item.keyEquivalentModifierMask = recKE.modifiers
        item.image = trayIcon("mic.circle")
        toggleMenuItem = item

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item)

        let meetingKE = menuKeyEquivalent(
            keyCode: UserDefaults.standard.integer(forKey: "meetingHotkeyKeyCode"),
            modifierMask: UserDefaults.standard.integer(forKey: "meetingHotkeyModifierMask")
        )
        let recordMeeting = NSMenuItem(title: "Record Meeting", action: #selector(toggleMeeting),
                                        keyEquivalent: meetingKE.key)
        recordMeeting.keyEquivalentModifierMask = meetingKE.modifiers
        recordMeeting.image = trayIcon("waveform.circle")
        meetingMenuItem = recordMeeting
        menu.addItem(recordMeeting)

        let snipKE = menuKeyEquivalent(
            keyCode: UserDefaults.standard.integer(forKey: "snipHotkeyKeyCode"),
            modifierMask: UserDefaults.standard.integer(forKey: "snipHotkeyModifierMask")
        )
        let snip = NSMenuItem(title: "Text Snap…", action: #selector(snipScreenText),
                               keyEquivalent: snipKE.key)
        snip.keyEquivalentModifierMask = snipKE.modifiers
        snip.image = trayIcon("rectangle.dashed.and.paperclip")
        menu.addItem(snip)

        let translateKE = menuKeyEquivalent(
            keyCode: UserDefaults.standard.integer(forKey: "translateHotkeyKeyCode"),
            modifierMask: UserDefaults.standard.integer(forKey: "translateHotkeyModifierMask")
        )
        let translate = NSMenuItem(title: "Translate Snap…", action: #selector(translateScreenText),
                                    keyEquivalent: translateKE.key)
        translate.keyEquivalentModifierMask = translateKE.modifiers
        translate.image = trayIcon("globe")
        menu.addItem(translate)

        let upload = NSMenuItem(title: "Upload Audio File…", action: #selector(uploadAudioFile), keyEquivalent: "")
        upload.image = trayIcon("arrow.up.doc")
        menu.addItem(upload)

        let transcriptsKE = menuKeyEquivalent(
            keyCode: UserDefaults.standard.integer(forKey: "transcriptsHotkeyKeyCode"),
            modifierMask: UserDefaults.standard.integer(forKey: "transcriptsHotkeyModifierMask")
        )
        let transcripts = NSMenuItem(title: "Transcripts…", action: #selector(openTranscripts),
                                       keyEquivalent: transcriptsKE.key)
        transcripts.keyEquivalentModifierMask = transcriptsKE.modifiers
        transcripts.image = trayIcon("doc.text.magnifyingglass")
        menu.addItem(transcripts)

        menu.addItem(NSMenuItem.separator())

        // "Check for Updates…" moved to Settings → Home → Updates section so
        // the tray menu stays focused on action-taking, not maintenance.

        // Audio submenu sits right above Settings — quick mic switch is the
        // most-used "settings-like" tray action.
        let audioParent = NSMenuItem(title: "Audio", action: nil, keyEquivalent: "")
        audioParent.image = trayIcon("speaker.wave.3")
        let audioSubmenu = NSMenu()
        audioParent.submenu = audioSubmenu
        audioMenuItem = audioParent
        audioSubmenuRef = audioSubmenu
        rebuildAudioSubmenu()
        menu.addItem(audioParent)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.image = trayIcon("gearshape")
        menu.addItem(settings)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit SolWhisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = trayIcon("power")
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func trayIcon(_ symbol: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    private func setupHotkey() {
        hotkeyManager = HotkeyManager()
        hotkeyManager?.onHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.toggleRecording()
            }
        }
        hotkeyManager?.onPauseHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.pauseRecording()
            }
        }
        hotkeyManager?.onSnipHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.snipScreenText()
            }
        }
        hotkeyManager?.onMeetingHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.toggleMeeting()
            }
        }
        hotkeyManager?.onTranscriptsHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.openTranscripts()
            }
        }
        hotkeyManager?.onTranslateHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.translateScreenText()
            }
        }
        hotkeyManager?.onVoiceTranslateHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.toggleVoiceTranslate()
            }
        }
        hotkeyManager?.startListening()
    }

    @objc func translateScreenText() {
        translationController.translate()
    }

    /// Voice-translate hotkey: press to start, press again to stop. Mirrors
    /// `toggleRecording`, but the active session translates before pasting.
    /// Ignored if a plain dictation session is already running.
    @objc func toggleVoiceTranslate() {
        DebugLog.shared.log(icon: "🌍", label: "VT-DIAG hotkey fired",
                            value: "isRecording=\(transcriptionController.isRecording) active=\(isVoiceTranslateActive)",
                            ok: false)
        if transcriptionController.isRecording {
            if isVoiceTranslateActive {
                stopRecording()
            } else {
                DebugLog.shared.log(icon: "🌍", label: "Voice-translate ignored",
                                    value: "dictation in progress")
            }
        } else {
            startRecording(voiceTranslate: true)
        }
    }

    /// Presents the shared translate bubble seeded with a voice transcript,
    /// pre-selected to the Voice Translate default language. Reuses the exact
    /// translation path Text Snap uses.
    @MainActor
    private func presentVoiceTranslateBubble(transcript: String, target: NSRunningApplication?) {
        let bubble = TranslateResultBubble(
            sourceText: transcript,
            pasteTarget: target,
            initialTargetOverride: voiceTranslateController.targetCode,
            onDismiss: { [weak self] in self?.voiceTranslateBubble = nil }
        )
        voiceTranslateBubble = bubble
        bubble.present()
        DebugLog.shared.log(icon: "🌍", label: "Voice-translate bubble",
                            value: "→ \(voiceTranslateController.targetCode)")
    }

    @objc func snipScreenText() {
        snipperController.snip()
    }

    @objc func toggleRecording() {
        if transcriptionController.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    /// Wall-clock start of the current dictation session. Used to compute
    /// `durationSeconds` for the history entry.
    private var recordingStartedAt: Date?

    func startRecording(voiceTranslate: Bool = false) {
        isVoiceTranslateActive = voiceTranslate
        DebugLog.shared.log(icon: "🌍", label: "VT-DIAG startRecording",
                            value: "voiceTranslate=\(voiceTranslate)", ok: false)
        // Snapshot the frontmost app RIGHT NOW — before the overlay appears.
        // pasteTarget (notification-based) is a fallback; frontmostApplication is
        // more reliable when triggered via hotkey while the user is in another app.
        let frontmost = NSWorkspace.shared.frontmostApplication
        recordingTarget = (frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier)
            ? frontmost : pasteTarget
        recordingStartedAt = Date()
        DebugLog.shared.log(icon: "🎙", label: "Start recording",
                            value: "target=\(recordingTarget?.localizedName ?? "nil")")

        if overlayWindowController == nil {
            overlayWindowController = OverlayWindowController(
                transcriptionController: transcriptionController,
                onStop:   { [weak self] in self?.stopRecording()   },
                onCancel: { [weak self] in self?.cancelRecording() },
                onPause:  { [weak self] in self?.pauseRecording()  }
            )
        }
        overlayWindowController?.showOverlay()
        transcriptionController.startRecording()
        updateStatusBarIcon(recording: true)

        // Pause music / lower playback volume per user preference.
        PlaybackController.recordingDidStart()
        AudioFeedback.play(.start)

        // Global ESC monitor — fires even when our non-activating panel isn't key
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.cancelRecording(viaEsc: true) }
            }
        }
    }

    func stopRecording() {
        let target = recordingTarget
        removeEscMonitor()
        DebugLog.shared.log(icon: "🛑", label: "Stop recording",
                            value: "target=\(target?.localizedName ?? "nil")")

        // Show processing dots while transcription finalizes + LLM polishes
        overlayWindowController?.showProcessing()
        updateStatusBarIcon(recording: false)

        let startedAt = recordingStartedAt
        recordingStartedAt = nil
        let backend = UserDefaults.standard.string(forKey: "transcriptionBackend") ?? "apple"

        // Capture + reset the voice-translate flag now so the next session
        // starts clean regardless of how this one ends.
        let translateActive = isVoiceTranslateActive
        isVoiceTranslateActive = false
        DebugLog.shared.log(icon: "🌍", label: "VT-DIAG stop",
                            value: "translateActive=\(translateActive)", ok: false)

        AudioFeedback.play(.stop)
        PlaybackController.recordingDidEnd()

        transcriptionController.stopRecording { [weak self] text in
            Task { @MainActor in
                guard let text = text, !text.isEmpty else {
                    // Nil/empty means nothing was transcribed — a genuinely
                    // silent take, or (on the Apple→WhisperKit rescue path) a
                    // 60s offline-transcribe timeout/failure. Either way the
                    // overlay was showing processing dots; force-hiding it here
                    // makes the pill just vanish with no explanation. Show a
                    // brief banner instead so "I dictated and nothing happened"
                    // becomes a visible, recoverable moment.
                    DebugLog.shared.log(icon: "🛑", label: "No text to paste", ok: false)
                    self?.overlayWindowController?.showAudioError(
                        "Nothing was transcribed — try again. If you have Apple Dictation off, download a WhisperKit model in Settings → Models.",
                        duration: 3.0) { [weak self] in
                        self?.overlayWindowController?.hideOverlay()
                    }
                    return
                }

                // Force-remove overlay immediately so it can't intercept focus/events
                self?.overlayWindowController?.forceHide()

                // Voice-translate mode: hand the transcript to the SAME
                // translation bubble Text Snap uses — proven Apple/LLM
                // translation, source auto-detect, language dropdown, and paste.
                // We do NOT run the dictation paste path in this case.
                if translateActive, let self {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    self.presentVoiceTranslateBubble(transcript: text, target: target)
                    let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
                    DictationHistoryStore.shared.record(DictationEntry(
                        durationSeconds: duration,
                        backend: backend,
                        originalText: text,
                        polishedText: text,
                        targetAppBundleID: target?.bundleIdentifier,
                        targetAppName: target?.localizedName
                    ))
                    return
                }

                // Let the window server fully remove the panel before pasting
                try? await Task.sleep(nanoseconds: 100_000_000)

                // Always copy to clipboard so the user can ⌘V manually if
                // auto-paste is off OR the paste fails. Additive-clipboard
                // mode appends instead of replacing.
                let pasteboardText = AdditiveClipboard.shared.write(text)

                let autoPaste = (UserDefaults.standard.object(forKey: "dictationAutoPaste") as? Bool) ?? true
                if autoPaste {
                    await PasteManager.paste(text: pasteboardText, into: target)
                }

                // Record into dictation history.
                let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
                DictationHistoryStore.shared.record(DictationEntry(
                    durationSeconds: duration,
                    backend: backend,
                    originalText: text,
                    polishedText: text,
                    targetAppBundleID: target?.bundleIdentifier,
                    targetAppName: target?.localizedName
                ))
            }
        }
    }

    func cancelRecording(viaEsc: Bool = false) {
        removeEscMonitor()
        isVoiceTranslateActive = false
        transcriptionController.cancel()
        updateStatusBarIcon(recording: false)
        if viaEsc {
            // Global ESC fires even from other apps — flash a note so a dictation
            // isn't silently discarded when the user pressed Esc for something else.
            overlayWindowController?.showAudioError("Dictation cancelled (Esc)", duration: 1.6) { [weak self] in
                self?.overlayWindowController?.hideOverlay()
            }
        } else {
            overlayWindowController?.hideOverlay()
        }
    }

    func pauseRecording() {
        guard transcriptionController.isRecording else { return }
        transcriptionController.togglePause()
        overlayWindowController?.togglePausePhase()
        let paused = transcriptionController.isPaused
        DebugLog.shared.log(icon: paused ? "⏸" : "▶️",
                            label: paused ? "Paused" : "Resumed")
    }

    private func removeEscMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
                .environmentObject(secretsStore)
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 672, height: 500),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            settingsWindow?.title = "SolWhisper Settings"
            settingsWindow?.toolbar = nil          // suppress macOS 26 auto zoom toolbar
            settingsWindow?.contentView = NSHostingView(rootView: settingsView)
            settingsWindow?.center()
            settingsWindow?.isReleasedWhenClosed = false
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Transcripts window

    @objc func openTranscripts() {
        if transcriptsWindowController == nil {
            transcriptsWindowController = TranscriptsWindowController(
                store: meetingStore,
                onUpload: { [weak self] in self?.uploadAudioFile() },
                meetingController: meetingController,
                importQueue: importQueue
            )
        }
        transcriptsWindowController?.openAndReload()
    }

    /// Same as `openTranscripts` but additionally drives selection to the
    /// given meeting. Used by the post-recording handoff so the user lands
    /// on the call that just finished, with its pipeline progress visible.
    func openTranscriptsAndSelect(_ meetingID: UUID) {
        if transcriptsWindowController == nil {
            transcriptsWindowController = TranscriptsWindowController(
                store: meetingStore,
                onUpload: { [weak self] in self?.uploadAudioFile() },
                meetingController: meetingController,
                importQueue: importQueue
            )
        }
        transcriptsWindowController?.openAndSelect(meetingID: meetingID)
    }

    // MARK: - File import (mode B)

    @objc func uploadAudioFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = []
        panel.allowedFileTypes = Array(FileTranscriber.acceptedExtensions)
        panel.message = "Choose audio file(s) to transcribe"
        panel.prompt = "Import"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        importQueue.enqueue(panel.urls)
    }

    /// Triggered by drag-and-drop onto the Dock icon (`CFBundleDocumentTypes`),
    /// or via `open` from Finder. `enqueue` filters to supported audio, dedupes,
    /// and surfaces the Transcripts window so the queue is visible.
    func application(_ application: NSApplication, open urls: [URL]) {
        importQueue.enqueue(urls)
    }

    // MARK: - Import result reporting

    /// A lone import surfaces its failure as an error pop-up; a multi-file batch
    /// shows an end-of-run log of what worked and what didn't. Deferred out of
    /// the queue's completion call stack before going modal.
    private func presentImportReport(_ report: ImportQueue.BatchReport) {
        let total = report.succeeded.count + report.failed.count + report.cancelled.count
        guard total > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.showImportReport(report, total: total)
        }
    }

    private func showImportReport(_ report: ImportQueue.BatchReport, total: Int) {
        let alert = NSAlert()
        alert.addButton(withTitle: "OK")

        if total == 1 {
            // A lone success is self-evident — only interrupt on failure.
            guard let failure = report.failed.first else { return }
            alert.alertStyle = .warning
            alert.messageText = "Couldn't import \(failure.name)"
            alert.informativeText = failure.reason
        } else {
            alert.alertStyle = report.failed.isEmpty ? .informational : .warning
            let imported = report.succeeded.count
            alert.messageText = (report.failed.isEmpty && report.cancelled.isEmpty)
                ? "Imported \(imported) file\(imported == 1 ? "" : "s")"
                : "Imported \(imported) of \(total) files"
            alert.informativeText = Self.importLog(report)
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Builds the multi-file log body: failures listed in full (with reasons);
    /// successes/cancellations listed but capped so a huge batch stays legible.
    private static func importLog(_ report: ImportQueue.BatchReport) -> String {
        var blocks: [String] = []
        if !report.succeeded.isEmpty {
            blocks.append("✓ Imported \(report.succeeded.count):\n" + capped(report.succeeded))
        }
        if !report.failed.isEmpty {
            let rows = report.failed.map { "   \($0.name) — \($0.reason)" }.joined(separator: "\n")
            blocks.append("✗ Failed \(report.failed.count):\n" + rows)
        }
        if !report.cancelled.isEmpty {
            blocks.append("– Cancelled \(report.cancelled.count):\n" + capped(report.cancelled))
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func capped(_ names: [String], limit: Int = 15) -> String {
        let shown = names.prefix(limit).map { "   \($0)" }
        let extra = names.count - shown.count
        return (shown + (extra > 0 ? ["   …and \(extra) more"] : [])).joined(separator: "\n")
    }

    // MARK: - Onboarding

    @objc func openOnboardingFromMenu() { openOnboarding() }

    /// Triggers a manual Sparkle update check from the About pane button.
    func checkForUpdatesNow() {
        updaterController.checkForUpdates(nil)
    }

    /// Bumps users who were on the original `⌥⌘` defaults (mask 10) up to the
    /// new `⌃⌥⌘` defaults (mask 11). Anyone with custom hotkeys keeps theirs.
    /// Idempotent — once `hotkeyDefaultsMigratedToHyper` is set, never re-runs.
    private func migrateLegacyHotkeyDefaultsIfNeeded() {
        let key = "hotkeyDefaultsMigratedToHyper"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let d = UserDefaults.standard

        // Record (R = 15)
        if d.integer(forKey: "hotkeyKeyCode") == 15
            && d.integer(forKey: "hotkeyModifierMask") == 10 {
            d.set(11, forKey: "hotkeyModifierMask")
        }
        // Pause (P = 35)
        if d.integer(forKey: "pauseHotkeyKeyCode") == 35
            && d.integer(forKey: "pauseHotkeyModifierMask") == 10 {
            d.set(11, forKey: "pauseHotkeyModifierMask")
        }
        d.set(true, forKey: key)
        DebugLog.shared.log(icon: "⌨️", label: "Hotkey defaults migrated",
                            value: "⌥⌘ → ⌃⌥⌘ for matching defaults")
    }

    func openOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                self.onboardingWindow?.close()
            }
            .environmentObject(secretsStore)
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "Welcome to SolWhisper"
            win.titlebarAppearsTransparent = true
            win.toolbar = nil
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.contentView = NSHostingView(rootView: view)
            onboardingWindow = win
        }
        onboardingWindow?.center()
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildAudioSubmenu()

        let isRec = transcriptionController.isRecording
        toggleMenuItem?.title = isRec ? "Stop Recording" : "Start Recording"
        toggleMenuItem?.image = trayIcon(isRec ? "stop.circle" : "mic.circle")

        switch meetingController.state {
        case .idle:
            meetingMenuItem?.title = "Record meeting"
            meetingMenuItem?.image = trayIcon("waveform.circle")
            meetingMenuItem?.isEnabled = true
        case .starting:
            meetingMenuItem?.title = "Starting meeting…"
            meetingMenuItem?.image = trayIcon("waveform.circle")
            meetingMenuItem?.isEnabled = false
        case .recording:
            meetingMenuItem?.title = "Stop Meeting"
            meetingMenuItem?.image = trayIcon("stop.circle.fill")
            meetingMenuItem?.isEnabled = true
        case .paused:
            meetingMenuItem?.title = "Stop Meeting (paused)"
            meetingMenuItem?.image = trayIcon("stop.circle")
            meetingMenuItem?.isEnabled = true
        case .stopping:
            meetingMenuItem?.title = "Stopping Meeting…"
            meetingMenuItem?.isEnabled = false
        case .processing:
            meetingMenuItem?.title = "Transcribing Meeting…"
            meetingMenuItem?.image = trayIcon("waveform.path.ecg")
            meetingMenuItem?.isEnabled = false
        }
    }

    @objc func toggleMeeting() {
        switch meetingController.state {
        case .idle:
            meetingController.start()
        case .recording, .paused:
            meetingController.stop()
        default:
            break  // starting / stopping / processing — disabled in menuWillOpen
        }
    }

    // MARK: - Audio submenu

    /// Rebuilds the tray Audio submenu. Called on menu open + after the
    /// preferredInputDeviceChanged notification fires.
    private func rebuildAudioSubmenu() {
        guard let submenu = audioSubmenuRef else { return }
        submenu.removeAllItems()

        let currentUID = PreferredInputDevice.uid

        // System default row
        let defaultItem = NSMenuItem(title: "System default",
                                      action: #selector(selectAudioInput(_:)),
                                      keyEquivalent: "")
        defaultItem.target = self
        defaultItem.representedObject = ""   // empty = system default
        defaultItem.state = (currentUID == nil) ? .on : .off
        submenu.addItem(defaultItem)
        submenu.addItem(NSMenuItem.separator())

        // Devices
        let devices = PreferredInputDevice.availableInputs()
        if devices.isEmpty {
            let none = NSMenuItem(title: "(no input devices)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        } else {
            for d in devices {
                let item = NSMenuItem(title: d.name,
                                      action: #selector(selectAudioInput(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = d.uid
                item.state = (d.uid == currentUID) ? .on : .off
                submenu.addItem(item)
            }
        }

    }

    @objc func selectAudioInput(_ sender: NSMenuItem) {
        let raw = sender.representedObject as? String ?? ""
        PreferredInputDevice.set(uid: raw.isEmpty ? nil : raw)
        rebuildAudioSubmenu()
    }

    // MARK: - Recording state UI helpers

    /// Converts a (keyCode, modifierMask) pair from our hotkey storage into
    /// the lowercase string + NSEvent.ModifierFlags shape that NSMenuItem
    /// uses for its keyEquivalent. Returns ("", []) when the user hasn't
    /// configured a hotkey, so the menu item just shows nothing.
    private func menuKeyEquivalent(keyCode: Int,
                                    modifierMask: Int) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        guard keyCode > 0 else { return ("", []) }
        var mods: NSEvent.ModifierFlags = []
        if modifierMask & 1 != 0 { mods.insert(.control) }
        if modifierMask & 2 != 0 { mods.insert(.option) }
        if modifierMask & 4 != 0 { mods.insert(.shift) }
        if modifierMask & 8 != 0 { mods.insert(.command) }
        // AppKit renders these special characters as the matching glyph
        // (Space, ↩, ⇥, ⌫, ⎋, arrows) in the menu — same as system menus do.
        let specials: [Int: String] = [
            36: "\r",                       // Return
            48: "\t",                       // Tab
            49: " ",                        // Space
            51: "\u{0008}",                 // Backspace
            53: "\u{001B}",                 // Escape
            123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}"
        ]
        if let special = specials[keyCode] {
            return (special, mods)
        }
        let raw = keyCodeToString(keyCode)
        let key = raw.count == 1 ? raw.lowercased() : ""
        return (key, mods)
    }

    func updateStatusBarIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }

        if recording {
            // Anthropic orange (#D97757) — distinct from the system red mic
            // glyph so users can tell SolWhisper recording apart from
            // macOS's own privacy indicator.
            let symbol = NSImage(systemSymbolName: "record.circle.fill",
                                  accessibilityDescription: "Recording")
            let config = NSImage.SymbolConfiguration(paletteColors: [
                NSColor(red: 217/255.0, green: 119/255.0, blue: 87/255.0, alpha: 1.0)
            ])
            button.image = symbol?.withSymbolConfiguration(config)
            // Multi-color symbol — must NOT be a template, otherwise AppKit
            // strips the tint.
            button.image?.isTemplate = false
        } else if let icon = NSImage(named: "MenuBarIcon") {
            icon.isTemplate = true
            icon.size = NSSize(width: 18, height: 18)
            button.image = icon
        } else {
            let fallback = NSImage(systemSymbolName: "waveform.circle",
                                    accessibilityDescription: "SolWhisper")
            fallback?.isTemplate = true
            button.image = fallback
        }
    }
}

import AppKit
import AVFoundation
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
    private var escMonitor: Any?

    /// Continuously updated — always the last app that had focus before SolWhisper.
    private var pasteTarget: NSRunningApplication?
    /// Locked-in at startRecording() — the app that should receive the paste.
    private var recordingTarget: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "enableLLMPolish":    true,
            "audioEnhancement":   true,
            "hotkeyKeyCode":      15,
            "hotkeyModifierMask": 10,
            "pauseHotkeyKeyCode":      35,   // P
            "pauseHotkeyModifierMask": 10,   // ⌥⌘
            "openRouterModel":    "anthropic/claude-3-5-haiku",
            "customVocabulary":   "[]",
            "polishRemoveFiller":   true,
            "polishFixPunctuation": true,
            "polishFixGrammar":     false,
            "showLiveTranscript":   true,
        ])
        // Migrate any previously stored invalid model IDs
        let storedModel = UserDefaults.standard.string(forKey: "openRouterModel") ?? ""
        let invalidModels = ["anthropic/claude-haiku-4-5-20251001", "anthropic/claude-haiku-4-5", "anthropic/claude-sonnet-4-6"]
        if invalidModels.contains(storedModel) {
            UserDefaults.standard.set("anthropic/claude-3-5-haiku", forKey: "openRouterModel")
        }
        seedLocalSecrets()
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

            // Show alert after a brief delay so the menu bar is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let alert = NSAlert()
                alert.messageText = "SolWhisper needs permissions"
                alert.informativeText = "The following permissions are not granted:\n\n\(list)\n\nOpen System Settings → Privacy & Security to enable them."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
            }
        } else {
            DebugLog.shared.log(icon: "✅", label: "All permissions granted")
        }
    }

    /// Seeds UserDefaults from Resources/local-secrets.json (gitignored, never committed).
    /// Safe to call repeatedly — only writes if the key is not already set.
    private func seedLocalSecrets() {
        guard let url = Bundle.main.url(forResource: "local-secrets", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let secrets = try? JSONDecoder().decode([String: String].self, from: data) else { return }

        for (key, value) in secrets where !value.isEmpty {
            if (UserDefaults.standard.string(forKey: key) ?? "").isEmpty {
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

        let item = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        item.keyEquivalentModifierMask = [.option, .command]
        toggleMenuItem = item

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(item)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: ""))
        menu.items.last?.target = updaterController
        menu.addItem(NSMenuItem(title: "Settings…",    action: #selector(openSettings),    keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Setup Guide…", action: #selector(openOnboardingFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit SolWhisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
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
        hotkeyManager?.startListening()
    }

    @objc func toggleRecording() {
        if transcriptionController.isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        // Snapshot the frontmost app RIGHT NOW — before the overlay appears.
        // pasteTarget (notification-based) is a fallback; frontmostApplication is
        // more reliable when triggered via hotkey while the user is in another app.
        let frontmost = NSWorkspace.shared.frontmostApplication
        recordingTarget = (frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier)
            ? frontmost : pasteTarget
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

        // Global ESC monitor — fires even when our non-activating panel isn't key
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.cancelRecording() }
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

        transcriptionController.stopRecording { [weak self] text in
            Task { @MainActor in
                // Force-remove overlay immediately so it can't intercept focus/events
                self?.overlayWindowController?.forceHide()

                guard let text = text, !text.isEmpty else {
                    DebugLog.shared.log(icon: "🛑", label: "No text to paste", ok: false)
                    return
                }

                // Let the window server fully remove the panel before pasting
                try? await Task.sleep(nanoseconds: 100_000_000)
                await PasteManager.paste(text: text, into: target)
            }
        }
    }

    func cancelRecording() {
        removeEscMonitor()
        transcriptionController.cancel()
        overlayWindowController?.hideOverlay()
        updateStatusBarIcon(recording: false)
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
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
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

    // MARK: - Onboarding

    @objc func openOnboardingFromMenu() { openOnboarding() }

    func openOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                self.onboardingWindow?.close()
            }
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
        let isRec = transcriptionController.isRecording
        toggleMenuItem?.title = isRec ? "Stop Recording" : "Start Recording"
    }

    // MARK: - Recording state UI helpers

    func updateStatusBarIcon(recording: Bool) {
        if recording {
            // Use system symbol for recording state (filled dot)
            statusItem?.button?.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")
        } else if let icon = NSImage(named: "MenuBarIcon") {
            icon.isTemplate = true
            icon.size = NSSize(width: 18, height: 18)
            statusItem?.button?.image = icon
        } else {
            statusItem?.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "SolWhisper")
        }
    }
}

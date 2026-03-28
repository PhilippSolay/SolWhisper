import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var overlayWindowController: OverlayWindowController?
    private var settingsWindow: NSWindow?
    private var hotkeyManager: HotkeyManager?

    let transcriptionController = TranscriptionController()
    private var previousApp: NSRunningApplication?
    private var escMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "enableLLMPolish":  true,
            "audioEnhancement": true,
            "hotkeyKeyCode":    15,
            "hotkeyModifierMask": 10,
        ])
        seedLocalSecrets()
        setupStatusBar()
        setupHotkey()
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "SolWhisper")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start Recording  ⌥⌘R", action: #selector(toggleRecording), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
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
        // Capture frontmost app NOW, before the overlay appears
        previousApp = NSWorkspace.shared.frontmostApplication

        if overlayWindowController == nil {
            overlayWindowController = OverlayWindowController(transcriptionController: transcriptionController)
        }
        overlayWindowController?.showOverlay()
        transcriptionController.startRecording()

        // Global ESC monitor — fires even when our non-activating panel isn't key
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.cancelRecording() }
            }
        }
    }

    func stopRecording() {
        let target = previousApp
        previousApp = nil
        removeEscMonitor()

        transcriptionController.stopRecording { [weak self] text in
            Task { @MainActor in
                self?.overlayWindowController?.hideOverlay()

                guard let text = text, !text.isEmpty else { return }

                // 1. Wait for overlay fade-out animation (150ms)
                try? await Task.sleep(nanoseconds: 200_000_000)

                // 2. Re-activate the app that had focus before recording
                target?.activate(options: .activateIgnoringOtherApps)

                // 3. Wait for it to become key and ready to accept keystrokes
                try? await Task.sleep(nanoseconds: 100_000_000)

                PasteManager.paste(text: text)
            }
        }
    }

    func cancelRecording() {
        removeEscMonitor()
        transcriptionController.cancel()
        overlayWindowController?.hideOverlay()
    }

    private func removeEscMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            settingsWindow?.title = "SolWhisper Settings"
            settingsWindow?.contentView = NSHostingView(rootView: settingsView)
            settingsWindow?.center()
            settingsWindow?.isReleasedWhenClosed = false
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

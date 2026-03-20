import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var overlayWindowController: OverlayWindowController?
    private var settingsWindow: NSWindow?
    private var hotkeyManager: HotkeyManager?

    let transcriptionController = TranscriptionController()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        if overlayWindowController == nil {
            overlayWindowController = OverlayWindowController(transcriptionController: transcriptionController)
        }
        overlayWindowController?.showOverlay()
        transcriptionController.startRecording()
    }

    func stopRecording() {
        transcriptionController.stopRecording { [weak self] text in
            Task { @MainActor in
                self?.overlayWindowController?.hideOverlay()
                if let text = text, !text.isEmpty {
                    PasteManager.paste(text: text)
                }
            }
        }
    }

    func cancelRecording() {
        transcriptionController.cancel()
        overlayWindowController?.hideOverlay()
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

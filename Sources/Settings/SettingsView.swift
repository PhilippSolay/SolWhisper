import SwiftUI
import AppKit

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("deepgramApiKey")     private var deepgramApiKey      = ""
    @AppStorage("openRouterApiKey")   private var openRouterApiKey    = ""
    @AppStorage("openRouterModel")    private var openRouterModel     = "anthropic/claude-haiku-4-5-20251001"
    @AppStorage("enableLLMPolish")    private var enableLLMPolish     = true
    @AppStorage("hotkeyKeyCode")      private var hotkeyKeyCode       = 15
    @AppStorage("hotkeyModifierMask") private var hotkeyModifierMask  = 10
    @AppStorage("audioEnhancement")   private var audioEnhancement    = true

    @State private var deepgramVisible    = false
    @State private var openRouterVisible  = false
    @State private var isRecordingHotkey  = false
    @State private var customModelText    = ""

    private let presetModels: [(id: String, label: String)] = [
        ("anthropic/claude-haiku-4-5-20251001", "Claude Haiku 4.5 (fast)"),
        ("anthropic/claude-sonnet-4-6",          "Claude Sonnet 4.6"),
        ("openai/gpt-4o-mini",                   "GPT-4o Mini"),
        ("openai/gpt-4o",                        "GPT-4o"),
        ("google/gemini-flash-1.5",              "Gemini Flash 1.5"),
        ("meta-llama/llama-3.1-8b-instruct",     "Llama 3.1 8B"),
    ]

    private var isCustomModel: Bool {
        !presetModels.map(\.id).contains(openRouterModel)
    }

    var body: some View {
        Form {
            // MARK: Transcription
            Section("Transcription") {
                APIKeyField(
                    label:   "Deepgram API Key",
                    text:    $deepgramApiKey,
                    visible: $deepgramVisible
                )

                Toggle("Audio enhancement", isOn: $audioEnhancement)
                if audioEnhancement {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Compression · AGC · Noise gate")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Boosts quiet mics, evens out volume spikes, and suppresses background noise before sending to Deepgram.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }
            }

            // MARK: LLM Polish
            Section("LLM Polish") {
                Toggle("Remove filler words & fix grammar", isOn: $enableLLMPolish)

                if enableLLMPolish {
                    APIKeyField(
                        label:   "OpenRouter API Key",
                        text:    $openRouterApiKey,
                        visible: $openRouterVisible
                    )

                    // Model picker
                    Picker("Model", selection: modelBinding) {
                        ForEach(presetModels, id: \.id) { m in
                            Text(m.label).tag(m.id)
                        }
                        Divider()
                        Text("Custom…").tag("custom")
                    }

                    if isCustomModel {
                        TextField("Model ID", text: $openRouterModel)
                            .textFieldStyle(.roundedBorder)
                            .help("e.g. mistralai/mistral-7b-instruct")
                    }
                }
            }

            // MARK: Hotkey
            Section("Hotkey") {
                HStack {
                    Text("Record shortcut")
                    Spacer()
                    HotkeyRecorderButton(
                        keyCode:      $hotkeyKeyCode,
                        modifierMask: $hotkeyModifierMask,
                        isRecording:  $isRecordingHotkey
                    )
                }
            }

            // MARK: About
            Section("About") {
                HStack {
                    Text("SolWhisper").fontWeight(.semibold)
                    Spacer()
                    Text("v0.1.0").foregroundColor(.secondary)
                }
                Link("Deepgram Console", destination: URL(string: "https://console.deepgram.com")!)
                Link("OpenRouter",       destination: URL(string: "https://openrouter.ai")!)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 500, height: 440)
    }

    // Map "custom" tag back to the stored free-text value
    private var modelBinding: Binding<String> {
        Binding(
            get: { isCustomModel ? "custom" : openRouterModel },
            set: { newVal in
                if newVal != "custom" { openRouterModel = newVal }
            }
        )
    }
}

// MARK: - API Key Field (copy/paste-friendly + eye toggle)

private struct APIKeyField: View {
    let label: String
    @Binding var text: String
    @Binding var visible: Bool

    var body: some View {
        HStack(spacing: 6) {
            if visible {
                TextField(label, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else {
                SecureField(label, text: $text)
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                visible.toggle()
            } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(visible ? "Hide key" : "Show key")
        }
    }
}

// MARK: - Hotkey Recorder Button

struct HotkeyRecorderButton: View {
    @Binding var keyCode: Int
    @Binding var modifierMask: Int
    @Binding var isRecording: Bool

    var body: some View {
        HotkeyRecorderRepresentable(
            keyCode:      $keyCode,
            modifierMask: $modifierMask,
            isRecording:  $isRecording
        )
        .frame(width: 140, height: 26)
    }
}

// MARK: - NSViewRepresentable recorder

private struct HotkeyRecorderRepresentable: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifierMask: Int
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let v = HotkeyRecorderNSView()
        v.onRecorded = { kc, mod in
            keyCode      = kc
            modifierMask = mod
            isRecording  = false
        }
        v.onRecordingStateChanged = { recording in
            isRecording = recording
        }
        return v
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.label        = hotkeyDisplayString(keyCode: keyCode, modifierMask: modifierMask)
        nsView.isRecording  = isRecording
        nsView.needsDisplay = true
    }
}

// MARK: - HotkeyRecorderNSView

final class HotkeyRecorderNSView: NSView {
    var label: String = ""
    var isRecording = false
    var onRecorded: ((Int, Int) -> Void)?
    var onRecordingStateChanged: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let text    = isRecording ? "Press shortcut…" : (label.isEmpty ? "Click to record" : label)
        let color   = isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        let bgColor = isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.1)
                                  : NSColor.controlBackgroundColor

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        bgColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let strSize = str.size()
        str.draw(at: NSPoint(
            x: (bounds.width - strSize.width) / 2,
            y: (bounds.height - strSize.height) / 2
        ))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        onRecordingStateChanged?(true)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }

        // Ignore modifier-only presses and ESC (cancel)
        if event.keyCode == 53 {
            isRecording = false
            onRecordingStateChanged?(false)
            window?.makeFirstResponder(nil)
            needsDisplay = true
            return
        }

        let mod = modifierMaskFromFlags(event.modifierFlags)
        guard mod != 0 else { return } // require at least one modifier

        onRecorded?(Int(event.keyCode), mod)
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        onRecordingStateChanged?(false)
        needsDisplay = true
        return super.resignFirstResponder()
    }
}

// MARK: - Helpers

/// Modifier bitmask: bit0=⌃ bit1=⌥ bit2=⇧ bit3=⌘
func modifierMaskFromFlags(_ flags: NSEvent.ModifierFlags) -> Int {
    var m = 0
    if flags.contains(.control) { m |= 1 }
    if flags.contains(.option)  { m |= 2 }
    if flags.contains(.shift)   { m |= 4 }
    if flags.contains(.command) { m |= 8 }
    return m
}

func hotkeyDisplayString(keyCode: Int, modifierMask: Int) -> String {
    var s = ""
    if modifierMask & 1 != 0 { s += "⌃" }
    if modifierMask & 2 != 0 { s += "⌥" }
    if modifierMask & 4 != 0 { s += "⇧" }
    if modifierMask & 8 != 0 { s += "⌘" }
    s += keyCodeToString(keyCode)
    return s
}

// keyCodeToString is defined in RecordingOverlayView.swift

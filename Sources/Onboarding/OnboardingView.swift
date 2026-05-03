import SwiftUI

// MARK: - Step enum

enum OnboardingStep: Int, CaseIterable {
    case welcome        = 0
    case chooseBackend  = 1
    case backendDetail  = 2
    case llmPolish      = 3
    case meetings       = 4
    case hotkey         = 5
    case allSet         = 6
}

// MARK: - Container

struct OnboardingView: View {

    @EnvironmentObject private var secrets: SecretsStore
    @AppStorage("transcriptionBackend")  private var backend          = "apple"
    @AppStorage("deepgramApiKey")        private var deepgramApiKey   = ""
    @AppStorage("enableLLMPolish")       private var enableLLMPolish  = true
    @AppStorage("hotkeyKeyCode")           private var hotkeyKeyCode           = 15
    @AppStorage("hotkeyModifierMask")      private var hotkeyModifierMask      = 10
    @AppStorage("pauseHotkeyKeyCode")      private var pauseHotkeyKeyCode      = 35
    @AppStorage("pauseHotkeyModifierMask") private var pauseHotkeyModifierMask = 10

    @State private var step: OnboardingStep = .welcome
    @State private var deepgramVisible       = false
    @State private var openRouterVisible     = false
    @State private var isRecordingHotkey     = false
    @State private var isRecordingPauseHotkey = false

    var onComplete: () -> Void

    // MARK: Validation

    private var canContinue: Bool {
        switch step {
        case .backendDetail: return backend == "apple" || !deepgramApiKey.isEmpty
        case .llmPolish:     return !enableLLMPolish   || !secrets.openRouterApiKey.isEmpty
        default:             return true
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            stepDots
                .padding(.top, 28)

            ZStack {
                stepContent
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .leading ).combined(with: .opacity)
                    ))
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.84), value: step)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            navBar
                .padding(.bottom, 32)
        }
        .frame(width: 540, height: 500)
    }

    // MARK: Step dots

    private var stepDots: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { s in
                Circle()
                    .fill(s.rawValue <= step.rawValue ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: s == step ? 8 : 6, height: s == step ? 8 : 6)
                    .animation(.spring(response: 0.3), value: step)
            }
        }
    }

    // MARK: Step content router

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:       welcomeStep
        case .chooseBackend: chooseBackendStep
        case .backendDetail: backendDetailStep
        case .llmPolish:     llmPolishStep
        case .meetings:      meetingsStep
        case .hotkey:        hotkeyStep
        case .allSet:        allSetStep
        }
    }

    // MARK: ── Meetings step ──

    private var meetingsStep: some View {
        stepShell(
            icon: "person.2.wave.2",
            title: "Record meetings (optional)",
            subtitle: "SolWhisper can capture mic + system audio so both sides of a call get transcribed."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                onboardingFeatureRow(icon: "lock.shield",
                                      text: "Audio stays on your Mac — nothing uploaded unless an integration is enabled")
                onboardingFeatureRow(icon: "rectangle.dashed.badge.record",
                                      text: "Needs Screen Recording permission to capture other apps' audio")
                onboardingFeatureRow(icon: "checkmark.circle",
                                      text: "First click on \"Record meeting\" prompts for the permission + a one-time consent disclaimer")
            }
            .padding(.top, 4)
            .padding(.horizontal, 8)

            Button("Open System Settings → Screen Recording") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            .controlSize(.regular)
        }
    }

    private func onboardingFeatureRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .frame(width: 22)
            Text(text).font(.system(size: 12))
        }
    }

    // MARK: Navigation bar

    private var navBar: some View {
        HStack {
            if step != .welcome {
                Button("Back") {
                    withAnimation {
                        if let prev = OnboardingStep(rawValue: step.rawValue - 1) { step = prev }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if step == .allSet {
                Button("Start Dictating") { onComplete() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.primary)
            } else {
                Button("Continue") {
                    withAnimation {
                        if let next = OnboardingStep(rawValue: step.rawValue + 1) { step = next }
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.primary)
                    .disabled(!canContinue)

                if step == .llmPolish {
                    Button("Skip") { withAnimation { step = .hotkey } }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                }
            }
        }
        .padding(.horizontal, 44)
    }

    // MARK: ── Step 0: Welcome ──

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            Image("SolWhisperLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text("Welcome to SolWhisper")
                    .font(.title2).fontWeight(.semibold)
                Text("Speak anywhere. Transcribe instantly.\nHit ⌥⌘R, say something — your words appear.")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
        }
        .padding(.horizontal, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: ── Step 1: Choose backend ──

    private var chooseBackendStep: some View {
        stepShell(
            icon: "brain",
            title: "Choose your engine",
            subtitle: "You can always change this in Settings."
        ) {
            Picker("", selection: $backend) {
                Text("Apple Speech").tag("apple")
                Text("Deepgram nova-3").tag("deepgram")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            // Description cards
            HStack(spacing: 12) {
                engineCard(
                    selected: backend == "apple",
                    icon: "apple.logo",
                    title: "Apple Speech",
                    bullets: ["Free · no API key", "On-device & private", "Works offline"]
                )
                engineCard(
                    selected: backend == "deepgram",
                    icon: "bolt.fill",
                    title: "Deepgram nova-3",
                    bullets: ["Higher accuracy", "Technical vocabulary", "Requires API key"]
                )
            }
            .frame(maxWidth: 420)
        }
    }

    private func engineCard(selected: Bool, icon: String, title: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            ForEach(bullets, id: \.self) { b in
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                        .foregroundColor(selected ? .primary : .secondary)
                    Text(b).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.primary.opacity(0.08) : Color.secondary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(selected ? Color.primary.opacity(0.4) : Color.clear, lineWidth: 1.5)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.spring(response: 0.2)) { backend = icon == "apple.logo" ? "apple" : "deepgram" } }
    }

    // MARK: ── Step 2: Backend detail ──

    @ViewBuilder
    private var backendDetailStep: some View {
        if backend == "apple" {
            stepShell(
                icon: "checkmark.seal.fill",
                title: "You're all set",
                subtitle: "Apple Speech runs on your Mac.\nNo API key or internet required."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    featureRow(icon: "lock.shield.fill",  text: "Audio never leaves your device")
                    featureRow(icon: "wifi.slash",        text: "Works completely offline")
                    featureRow(icon: "dollarsign.circle", text: "100% free, no usage limits")
                }
                .padding(.top, 4)
            }
        } else {
            stepShell(
                icon: "key.fill",
                title: "Add your Deepgram key",
                subtitle: "Get a free key with 12,000 minutes/year at console.deepgram.com"
            ) {
                APIKeyField(label: "Deepgram API Key", text: $deepgramApiKey, visible: $deepgramVisible)
                    .frame(maxWidth: 380)

                Link("Open Deepgram Console →",
                     destination: URL(string: "https://console.deepgram.com")!)
                    .font(.system(size: 12))
            }
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .frame(width: 22)
            Text(text).font(.system(size: 13))
        }
    }

    // MARK: ── Step 3: LLM Polish ──

    private var llmPolishStep: some View {
        stepShell(
            icon: "sparkles",
            title: "AI polish (optional)",
            subtitle: "Removes filler words and fixes grammar\nafter transcription. Uses OpenRouter."
        ) {
            Toggle("Enable AI polish", isOn: $enableLLMPolish)
                .toggleStyle(.switch)
                .frame(maxWidth: 380, alignment: .leading)

            if enableLLMPolish {
                APIKeyField(label: "OpenRouter API Key", text: $secrets.openRouterApiKey, visible: $openRouterVisible)
                    .frame(maxWidth: 380)

                Link("Get a free OpenRouter key →",
                     destination: URL(string: "https://openrouter.ai")!)
                    .font(.system(size: 12))

                Text("Stored securely in macOS Keychain.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: ── Step 4: Hotkey ──

    private var hotkeyStep: some View {
        stepShell(
            icon: "keyboard",
            title: "Set your hotkeys",
            subtitle: "Press any key combo to assign.\nYou can change these later in Settings."
        ) {
            VStack(spacing: 16) {
                // Record hotkey
                hotkeyRow(
                    label: "Record / Stop",
                    keyCode: $hotkeyKeyCode,
                    modifierMask: $hotkeyModifierMask,
                    isRecording: $isRecordingHotkey
                )

                // Pause hotkey
                hotkeyRow(
                    label: "Pause / Resume",
                    keyCode: $pauseHotkeyKeyCode,
                    modifierMask: $pauseHotkeyModifierMask,
                    isRecording: $isRecordingPauseHotkey
                )
            }
        }
    }

    private func hotkeyRow(label: String,
                           keyCode: Binding<Int>,
                           modifierMask: Binding<Int>,
                           isRecording: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                Text(hotkeyDisplayString(keyCode: keyCode.wrappedValue, modifierMask: modifierMask.wrappedValue))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HotkeyRecorderButton(
                keyCode:      keyCode,
                modifierMask: modifierMask,
                isRecording:  isRecording
            )
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 380)
    }

    // MARK: ── Step 5: All set ──

    private var allSetStep: some View {
        stepShell(
            icon: "party.popper.fill",
            title: "You're ready!",
            subtitle: "Press your hotkey anywhere to start recording."
        ) {
            VStack(spacing: 10) {
                hotkeyHint
                summaryRow(icon: backend == "apple" ? "apple.logo" : "bolt.fill",
                           label: "Engine",
                           value: backend == "apple" ? "Apple Speech" : "Deepgram nova-3")
                summaryRow(icon: "sparkles",
                           label: "AI Polish",
                           value: enableLLMPolish ? "On" : "Off")
            }
            .frame(maxWidth: 340)
        }
    }

    private var hotkeyHint: some View {
        VStack(spacing: 6) {
            summaryRow(icon: "keyboard",
                       label: "Record / Stop",
                       value: hotkeyDisplayString(keyCode: hotkeyKeyCode, modifierMask: hotkeyModifierMask))
            summaryRow(icon: "pause.circle",
                       label: "Pause / Resume",
                       value: hotkeyDisplayString(keyCode: pauseHotkeyKeyCode, modifierMask: pauseHotkeyModifierMask))
        }
    }

    private func summaryRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: ── Shared shell ──

    private func stepShell<Content: View>(
        icon: String, title: String, subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(.primary)
                .symbolRenderingMode(.hierarchical)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2).fontWeight(.semibold)
                Text(subtitle)
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            content()
                .padding(.top, 4)
        }
        .padding(.horizontal, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

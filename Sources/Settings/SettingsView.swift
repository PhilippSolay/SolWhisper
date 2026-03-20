import SwiftUI

struct SettingsView: View {
    @AppStorage("deepgramApiKey") private var deepgramApiKey = ""
    @AppStorage("openRouterApiKey") private var openRouterApiKey = ""
    @AppStorage("openRouterModel") private var openRouterModel = "anthropic/claude-haiku-4-5-20251001"
    @AppStorage("enableLLMPolish") private var enableLLMPolish = true
    @AppStorage("hotkeyModifiers") private var hotkeyModifiers = 786432 // Option + Command

    var body: some View {
        Form {
            Section("API Keys") {
                SecureField("Deepgram API Key", text: $deepgramApiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Toggle("LLM Polish (removes filler words)", isOn: $enableLLMPolish)
                }

                if enableLLMPolish {
                    SecureField("OpenRouter API Key", text: $openRouterApiKey)
                        .textFieldStyle(.roundedBorder)

                    TextField("Model", text: $openRouterModel)
                        .textFieldStyle(.roundedBorder)
                        .help("e.g. anthropic/claude-haiku-4-5-20251001 or openai/gpt-4o-mini")
                }
            }

            Section("Hotkey") {
                Text("Press ⌥⌘R to start/stop recording")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }

            Section("About") {
                HStack {
                    Text("SolWhisper")
                        .fontWeight(.semibold)
                    Spacer()
                    Text("v0.1.0")
                        .foregroundColor(.secondary)
                }
                Link("Deepgram Console", destination: URL(string: "https://console.deepgram.com")!)
                Link("OpenRouter", destination: URL(string: "https://openrouter.ai")!)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 480, height: 360)
    }
}

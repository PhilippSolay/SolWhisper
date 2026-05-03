import SwiftUI

struct OCRSettingsView: View {

    @AppStorage("ocrLineBreakMode")        private var lineBreakMode    = "keep"
    @AppStorage("ocrRecognitionLevel")     private var recognitionLevel = "accurate"
    @AppStorage("ocrUseLangCorrection")    private var useLangCorrection = true
    @AppStorage("ocrSilentCapture")        private var silentCapture    = true
    @AppStorage("ocrRecognitionLanguages") private var recognitionLanguages = ""
    @AppStorage("ocrAutoDetectLanguage")   private var autoDetectLanguage = false

    private let languageOptions: [(id: String, label: String)] = [
        ("",                "Auto (system)"),
        ("en-US",           "English"),
        ("es-ES",           "Spanish"),
        ("de-DE",           "German"),
        ("fr-FR",           "French"),
        ("it-IT",           "Italian"),
        ("pt-BR",           "Portuguese"),
        ("zh-Hans",         "Simplified Chinese"),
        ("zh-Hant",         "Traditional Chinese"),
        ("ja-JP",           "Japanese"),
        ("ko-KR",           "Korean"),
        ("ru-RU",           "Russian"),
        ("uk-UA",           "Ukrainian")
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Remove line breaks",
                       isOn: Binding(
                            get: { lineBreakMode == "remove" },
                            set: { lineBreakMode = $0 ? "remove" : "keep" }
                       ))
            } header: { Text("Result") } footer: {
                Text("When on, wrapped lines within a paragraph are joined with a space. Blank-line gaps between paragraphs are preserved.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Picker("Speed", selection: $recognitionLevel) {
                    Text("Accurate (default)").tag("accurate")
                    Text("Fast").tag("fast")
                }
                Toggle("Use language correction", isOn: $useLangCorrection)
                Picker("Recognition language", selection: $recognitionLanguages) {
                    ForEach(languageOptions, id: \.id) { Text($0.label).tag($0.id) }
                }
                .disabled(autoDetectLanguage)
                .help("Pin recognition to a specific language for faster, more accurate OCR when your captures are mostly one script.")
                Toggle("Automatically detect language", isOn: $autoDetectLanguage)
                    .help("Vision picks the best language from supported scripts. Overrides the manual selection above.")
            } header: { Text("Recognition") } footer: {
                Text("Primary text recognition language. Auto-detect lets Vision pick the best match from supported languages — overrides the manual selection.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Toggle("Silent capture (no shutter sound)", isOn: $silentCapture)
            } header: { Text("Capture") } footer: {
                Text("System content protection (DRM video, etc.) may blank some captures. Pick a hotkey in Settings → Hotkey.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Screen OCR")
    }
}

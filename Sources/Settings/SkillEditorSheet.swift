import SwiftUI

/// Create/edit form for user skills (Phase A — flat skills only).
///
/// Pack-level editing (the meeting-summary structure with parent + shared +
/// types) lands in v0.5 Phase B. For now this covers the 80% case: a user
/// who wants their own one-shot summary template (e.g. "Investor Update",
/// "Coaching Session") with a custom prompt + optional model override.
struct SkillEditorSheet: View {

    /// Pre-filled when editing; nil when creating.
    let editing: Skill?
    let onSave: (Skill) -> Void
    let onCancel: () -> Void

    @StateObject private var registry = SkillsRegistry.shared
    @StateObject private var modelStore = ModelStore.shared

    @State private var id: String
    @State private var name: String
    @State private var description: String
    @State private var promptTemplate: String
    @State private var outputTemplate: String
    @State private var defaultModelTag: String        // ConfiguredModel UUID, or "" = none
    @State private var defaultTemperature: Double
    @State private var validationError: String?

    init(editing: Skill?,
         onSave: @escaping (Skill) -> Void,
         onCancel: @escaping () -> Void) {
        self.editing = editing
        self.onSave = onSave
        self.onCancel = onCancel
        if let s = editing {
            _id = State(initialValue: s.id)
            _name = State(initialValue: s.name)
            _description = State(initialValue: s.description)
            _promptTemplate = State(initialValue: s.promptTemplate)
            _outputTemplate = State(initialValue: s.outputTemplate)
            _defaultTemperature = State(initialValue: s.defaultTemperature ?? 0.2)
            // Map legacy provider/model strings into either a UUID match
            // (best effort) or empty (= "use routing default").
            _defaultModelTag = State(initialValue: "")
        } else {
            _id = State(initialValue: "")
            _name = State(initialValue: "")
            _description = State(initialValue: "")
            _promptTemplate = State(initialValue: defaultStarterPrompt)
            _outputTemplate = State(initialValue: defaultStarterOutput)
            _defaultTemperature = State(initialValue: 0.2)
            _defaultModelTag = State(initialValue: "")
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("ID (slug, e.g. investor-update)", text: $id)
                    .textFieldStyle(.roundedBorder)
                    .disabled(editing != nil)   // ids are immutable post-create
                TextField("Name (e.g. Investor Update)", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("Description", text: $description, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...3)
            } header: {
                Text(editing == nil ? "New skill" : "Edit \(editing?.name ?? "skill")")
            } footer: {
                Text("ID becomes the filename and is used by the routing UI. Use a short slug — no spaces or slashes.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                TextEditor(text: $promptTemplate)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            } header: { Text("Prompt template") } footer: {
                Text("Use `{{transcript}}` and `{{participants}}` placeholders. The transcript will be substituted before the LLM call.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                TextEditor(text: $outputTemplate)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            } header: { Text("Output skeleton (optional)") } footer: {
                Text("Markdown headings the model should fill. Empty = no skeleton.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Picker("Default model (optional)", selection: $defaultModelTag) {
                    Text("Use routing default").tag("")
                    ForEach(modelStore.models) { m in
                        Text("\(m.provider.label) · \(m.label)").tag(m.id.uuidString)
                    }
                }
                HStack {
                    Text("Temperature")
                    Slider(value: $defaultTemperature, in: 0...1, step: 0.05)
                    Text(String(format: "%.2f", defaultTemperature))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(width: 36, alignment: .trailing)
                }
            } header: { Text("Defaults") } footer: {
                Text("Override the role-level routing for this skill, or leave on routing default. Temperature 0 = deterministic, 1 = creative.")
                    .font(.caption).foregroundColor(.secondary)
            }

            if let err = validationError {
                Section {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 620)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onCancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Commit

    private func commit() {
        if let err = registry.validateUserSkillID(id, existingID: editing?.id) {
            validationError = err
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationError = "Name is required."
            return
        }
        // Resolve the chosen ConfiguredModel back into provider + modelID
        // strings, since Skill stores them flat (legacy field shape kept
        // for compat with the existing summary path).
        var providerStr: String? = nil
        var modelIDStr: String? = nil
        if !defaultModelTag.isEmpty,
           let uuid = UUID(uuidString: defaultModelTag),
           let m = modelStore.models.first(where: { $0.id == uuid }) {
            providerStr = m.provider.rawValue
            modelIDStr = m.modelID
        }

        let s = Skill(
            id: id.trimmingCharacters(in: .whitespaces),
            name: trimmedName,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            promptTemplate: promptTemplate,
            outputTemplate: outputTemplate,
            defaultLLMProvider: providerStr,
            defaultLLMModel: modelIDStr,
            defaultTemperature: defaultTemperature,
            isBuiltIn: false
        )
        onSave(s)
    }
}

private let defaultStarterPrompt = """
You are a meeting summarizer. Produce a Markdown summary of the transcript below.

Sections:
- Overview (2-4 sentences)
- Key points (bullet list)
- Action items (per person, with owner and due date if stated)
- Open questions

Participants: {{participants}}

<transcript>
{{transcript}}
</transcript>
"""

private let defaultStarterOutput = """
## Overview

## Key points

## Action items

## Open questions
"""

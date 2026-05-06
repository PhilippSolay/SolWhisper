import SwiftUI

/// Review sheet for LLM-proposed speaker → name mappings. Shows each
/// speaker letter, its sample lines, the suggested name + confidence, and
/// a per-row text field the user can override. Accept commits the picked
/// names into the meeting's `speakerNames` map.
struct SuggestNamesSheet: View {

    let initialSuggestions: [SpeakerNameSuggester.Suggestion]
    let calendarCandidates: [String]
    let onApply: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var rowDrafts: [String: String] = [:]   // speakerID → name draft
    @State private var rowEnabled: [String: Bool] = [:]    // include this row in the apply

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Review suggested names")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("LLM suggestions — review before applying")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(initialSuggestions) { s in
                        suggestionRow(for: s)
                        Divider().opacity(0.3)
                    }
                }
            }

            Divider()
            HStack {
                Text("\(applyCount) of \(initialSuggestions.count) will be applied")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    onApply(applyMap)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(applyCount == 0)
            }
            .padding(16)
        }
        .frame(width: 620, height: 500)
        .onAppear {
            for s in initialSuggestions {
                rowDrafts[s.speakerID] = s.suggestedName ?? ""
                // Auto-include rows where confidence ≥ 0.6 and we have a name
                rowEnabled[s.speakerID] = (s.suggestedName != nil) && (s.confidence >= 0.6)
            }
        }
    }

    @ViewBuilder
    private func suggestionRow(for s: SpeakerNameSuggester.Suggestion) -> some View {
        let included = rowEnabled[s.speakerID] ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: Binding(
                    get: { rowEnabled[s.speakerID] ?? false },
                    set: { rowEnabled[s.speakerID] = $0 }
                )) {
                    Text("Speaker \(s.speakerID)")
                        .font(.system(size: 13, weight: .medium))
                }
                .toggleStyle(.checkbox)

                Spacer()

                ConfidenceBadge(value: s.confidence)
            }

            HStack(spacing: 6) {
                Text("Name:")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                if !calendarCandidates.isEmpty {
                    Menu {
                        ForEach(calendarCandidates, id: \.self) { c in
                            Button(c) {
                                rowDrafts[s.speakerID] = c
                                rowEnabled[s.speakerID] = true
                            }
                        }
                        Divider()
                        Button("Clear") { rowDrafts[s.speakerID] = "" }
                    } label: {
                        Image(systemName: "calendar")
                            .font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 26)
                    .help("Pick from calendar attendees")
                }
                TextField("Name", text: Binding(
                    get: { rowDrafts[s.speakerID] ?? "" },
                    set: { rowDrafts[s.speakerID] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .disabled(!included)
            }

            if !s.rationale.isEmpty {
                Text("Why: \(s.rationale)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            if !s.sampleLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(s.sampleLines.enumerated()), id: \.offset) { _, line in
                        Text("• \(line)")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .opacity(included ? 1.0 : 0.55)
    }

    private var applyMap: [String: String] {
        var out: [String: String] = [:]
        for (letter, on) in rowEnabled where on {
            let name = (rowDrafts[letter] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { out[letter] = name }
        }
        return out
    }

    private var applyCount: Int { applyMap.count }
}

private struct ConfidenceBadge: View {
    let value: Double
    var color: Color {
        if value >= 0.75 { return .green }
        if value >= 0.5  { return .orange }
        return .secondary
    }
    var body: some View {
        Text("\(Int((value * 100).rounded()))%")
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(color.opacity(0.15))
            )
    }
}

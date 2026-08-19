import SwiftUI

struct SkillsSettingsView: View {

    @StateObject private var registry = SkillsRegistry.shared
    @State private var editing: Skill?
    @State private var showEditor: Bool = false
    @State private var deleteConfirmTarget: Skill?

    /// All skills now live in the user folder (built-ins are seeded there
    /// on first launch and become editable). Kept as a property so the
    /// view body reads cleanly.
    private var userSkills: [Skill] { registry.skills }

    var body: some View {
        Form {
            Section {
                Text("Skills are summary templates — they decide what your meeting summary contains. Pick the default in **Meetings → Auto-pipeline**.")
                    .font(.caption).foregroundColor(.secondary)
            }

            if !registry.skillPacks.isEmpty {
                Section("Skill packs") {
                    ForEach(registry.skillPacks) { pack in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pack.name).font(.system(size: 13, weight: .medium))
                                    Text(pack.description)
                                        .font(.system(size: 11)).foregroundColor(.secondary)
                                        .lineLimit(3)
                                }
                                Spacer()
                                Text(pack.isBuiltIn ? "Built-in" : "User")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            if !pack.typeIDs.isEmpty {
                                Text("Sub-types: " + pack.typeIDs.joined(separator: ", "))
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                if userSkills.isEmpty {
                    Text("No skills yet. Click + below to create one, or use Restore default skills to bring back the built-in templates.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(userSkills) { skill in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name).font(.system(size: 13, weight: .medium))
                                Text(skill.description)
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button {
                                editing = skill
                                showEditor = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("Edit")
                            .accessibilityLabel("Edit skill")
                            Button(role: .destructive) {
                                deleteConfirmTarget = skill
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .help("Delete")
                            .accessibilityLabel("Delete skill")
                        }
                        .padding(.vertical, 2)
                    }
                }
                Button {
                    editing = nil
                    showEditor = true
                } label: {
                    Label("Add skill…", systemImage: "plus.circle")
                }
            } header: { Text("Skills") } footer: {
                Text("All skills live in the user skills folder and are fully editable. Built-ins are seeded automatically on first launch.")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section {
                Button("Restore default skills") {
                    registry.restoreMissingBuiltIns()
                }
                Button("Restore default skill pack") {
                    SkillPackLoader.restoreMissingBuiltInPacks()
                    registry.reload()
                }
                Button("Reveal user skills folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([SkillsRegistry.userSkillsDirectory])
                }
                Button("Reveal user skill packs folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([SkillPackLoader.userPacksDirectory])
                }
                Button("Reload skills") { registry.reload() }
            } footer: {
                Text("All skills and the meeting-summary pack live in your user folders and are fully editable. Restore re-copies any deleted built-in files from the bundle — without touching your edits. The pack is a folder of Markdown files (parent SKILL.md + shared/ extractors + types/<one>.md per meeting type) — edit any of them in your favorite Markdown editor and click Reload to pick up changes.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Skills")
        .sheet(isPresented: $showEditor) {
            SkillEditorSheet(
                editing: editing,
                onSave: { skill in
                    let result = registry.saveUserSkill(skill)
                    if case .failure(let err) = result {
                        DebugLog.shared.log(icon: "🪄", label: "Save user skill failed",
                                            value: "\(err)", ok: false)
                    }
                    showEditor = false
                    editing = nil
                },
                onCancel: {
                    showEditor = false
                    editing = nil
                }
            )
        }
        .alert("Delete this skill?",
               isPresented: Binding(
                get: { deleteConfirmTarget != nil },
                set: { if !$0 { deleteConfirmTarget = nil } }
               )) {
            Button("Cancel", role: .cancel) { deleteConfirmTarget = nil }
            Button("Delete", role: .destructive) {
                if let s = deleteConfirmTarget {
                    registry.deleteUserSkill(id: s.id)
                }
                deleteConfirmTarget = nil
            }
        } message: {
            Text("\"\(deleteConfirmTarget?.name ?? "")\" will be removed permanently. This can't be undone.")
        }
    }
}

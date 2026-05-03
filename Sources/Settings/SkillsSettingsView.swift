import SwiftUI

struct SkillsSettingsView: View {

    @StateObject private var registry = SkillsRegistry.shared

    var body: some View {
        Form {
            Section {
                Text("The default skill picker lives in **STT Meetings → Summary**.")
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

            Section("Skills") {
                if registry.skills.isEmpty {
                    Text("No flat skills loaded.")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(registry.skills) { skill in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name).font(.system(size: 13, weight: .medium))
                                Text(skill.description)
                                    .font(.system(size: 11)).foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text(skill.isBuiltIn ? "Built-in" : "User")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Section {
                Button("Reveal user skills folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([SkillsRegistry.userSkillsDirectory])
                }
                Button("Reload skills") { registry.reload() }
            } footer: {
                Text("Drop `.json` files into the user skills folder to add custom templates. Skill editor UI is on the v0.5 roadmap.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Skills")
    }
}

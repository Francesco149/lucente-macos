import LucenteKit
import SwiftUI

/// The editable copy of a group behind the editor sheet.
struct GroupDraft: Identifiable {
    let id = UUID()
    var editing: LightGroup?
    var name: String
    var members: Set<UUID>
    var controls: Set<Capability>

    @MainActor
    init(store: LightStore, editing: LightGroup? = nil) {
        self.editing = editing
        name = editing?.name ?? "Group \(store.groups.count + 1)"
        members = Set(editing?.members ?? [])
        controls = editing?.controls ?? Set(Capability.allCases)
    }
}

struct GroupEditor: View {
    @Environment(LightStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: GroupDraft
    var onSave: (UUID?) -> Void

    /// Controls every chosen member supports — the only ones worth offering.
    private var shared: [Capability] {
        let lights = store.lights.filter { draft.members.contains($0.id) }
        guard !lights.isEmpty else { return [] }
        return Capability.allCases.filter { cap in cap != .speed && lights.allSatisfy { $0.capabilities.contains(cap) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $draft.name)

                Section("Lights") {
                    ForEach(store.lights) { light in
                        Toggle(isOn: membership(light.id)) {
                            HStack(spacing: 8) {
                                Swatch(state: light.state, size: 12)
                                Text(light.name)
                                Text(light.driver.vendor).foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                }

                Section {
                    if shared.isEmpty {
                        Text("Choose lights to see the controls they share.").foregroundStyle(.secondary)
                    }
                    ForEach(shared, id: \.self) { cap in
                        Toggle(cap.title, isOn: control(cap))
                    }
                } header: {
                    Text("Controls")
                } footer: {
                    Text("Turn off what you don't want to drive together — for example, keep only Power for an all-lights switch.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.editing == nil ? "Create Group" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.members.isEmpty)
            }
            .padding()
        }
        .frame(width: 440, height: 520)
    }

    private func membership(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { draft.members.contains(id) },
            set: { if $0 { draft.members.insert(id) } else { draft.members.remove(id) } }
        )
    }

    private func control(_ cap: Capability) -> Binding<Bool> {
        Binding(
            get: { draft.controls.contains(cap) },
            set: { on in
                if on { draft.controls.insert(cap) } else { draft.controls.remove(cap) }
                // Effect speed rides along with effects.
                if cap == .effect { if on { draft.controls.insert(.speed) } else { draft.controls.remove(.speed) } }
            }
        )
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Group" : draft.name
        let members = store.lights.map(\.id).filter(draft.members.contains)
        if var group = draft.editing {
            group.name = name
            group.members = members
            group.controls = draft.controls
            store.update(group)
            onSave(group.id)
        } else {
            onSave(store.createGroup(name: name, members: members, controls: draft.controls).id)
        }
        dismiss()
    }
}

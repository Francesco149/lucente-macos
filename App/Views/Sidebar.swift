import LucenteKit
import SwiftUI

struct Sidebar: View {
    @Environment(LightStore.self) private var store
    @Binding var selection: SidebarItem?
    @Binding var groupDraft: GroupDraft?
    @Binding var savingScene: Bool

    var body: some View {
        List(selection: $selection) {
            Section("Lights") {
                if store.lights.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching…").foregroundStyle(.secondary)
                    }
                    .selectionDisabled()
                }
                ForEach(store.lights) { light in
                    LightRow(light: light)
                        .tag(SidebarItem.light(light.id))
                        .contextMenu { LightMenu(light: light) }
                }
            }

            Section {
                ForEach(store.groups) { group in
                    GroupRow(group: group)
                        .tag(SidebarItem.group(group.id))
                        .contextMenu {
                            Button("Edit Group…") { groupDraft = GroupDraft(store: store, editing: group) }
                            Divider()
                            Button("Delete Group", role: .destructive) { store.deleteGroup(group.id) }
                        }
                }
            } header: {
                SectionHeader(title: "Groups", help: "New group") { groupDraft = GroupDraft(store: store) }
            }

            Section {
                ForEach(store.scenes) { scene in
                    SceneRow(scene: scene)
                        .tag(SidebarItem.scene(scene.id))
                        .contextMenu {
                            Button("Apply") { store.apply(scene) }
                            Button("Update to Current Look") { store.recapture(scene.id) }
                            Divider()
                            Button("Delete Scene", role: .destructive) { store.deleteScene(scene.id) }
                        }
                }
                .onMove { store.moveScenes(from: $0, to: $1) }
            } header: {
                SectionHeader(title: "Scenes", help: "Save the current look as a scene") { savingScene = true }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand(perform: deleteSelection)
    }

    private func deleteSelection() {
        switch selection {
        case .group(let id)?: store.deleteGroup(id)
        case .scene(let id)?: store.deleteScene(id)
        default: return
        }
        selection = nil
    }
}

private struct SectionHeader: View {
    var title: LocalizedStringKey
    var help: LocalizedStringKey
    var add: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: add) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help(help)
        }
    }
}

struct LightRow: View {
    @Environment(LightStore.self) private var store
    let light: Light

    var body: some View {
        HStack(spacing: 10) {
            Swatch(state: light.state, size: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(light.name).lineLimit(1)
                Text(light.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            PowerToggle(isOn: light.state.power == true) { store.send(.power($0), to: light) }
                .disabled(!light.capabilities.contains(.power))
        }
        .opacity(light.isReachable ? 1 : 0.55)
        .padding(.vertical, 2)
    }
}

struct GroupRow: View {
    @Environment(LightStore.self) private var store
    let group: LightGroup

    var body: some View {
        let members = store.members(of: group)
        HStack(spacing: 10) {
            Swatch(state: store.state(of: group), size: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).lineLimit(1)
                Text("\(members.filter(\.isReachable).count) of \(members.count) available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if store.capabilities(of: group).contains(.power) {
                PowerToggle(isOn: store.state(of: group).power == true) { store.send(.power($0), to: group) }
            }
        }
        .padding(.vertical, 2)
    }
}

struct SceneRow: View {
    @Environment(LightStore.self) private var store
    let scene: LightScene

    var body: some View {
        HStack(spacing: 10) {
            SceneSwatches(scene: scene)
            Text(scene.name).lineLimit(1)
            Spacer(minLength: 4)
            Button("Apply") { store.apply(scene) }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}

/// Overlapping dots previewing a scene's colors.
struct SceneSwatches: View {
    let scene: LightScene

    var body: some View {
        let states = Array(scene.states.values.sorted { ($0.color?.hex ?? "") < ($1.color?.hex ?? "") }.prefix(3))
        ZStack {
            ForEach(Array(states.enumerated()), id: \.offset) { index, state in
                Swatch(state: state, size: 10).offset(x: CGFloat(index) * 5 - 5)
            }
        }
        .frame(width: 14, height: 14)
    }
}

struct PowerToggle: View {
    var isOn: Bool
    var set: @MainActor (Bool) -> Void

    var body: some View {
        Toggle("Power", isOn: Binding(get: { isOn }, set: set))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
    }
}

/// Per-light actions, shared by the sidebar context menu and the detail toolbar.
struct LightMenu: View {
    @Environment(LightStore.self) private var store
    let light: Light

    var body: some View {
        Button("Identify", systemImage: "sparkles") { Task { await store.identify(light) } }
        Button("Reconnect", systemImage: "arrow.triangle.2.circlepath") { store.reconnect(light) }
        Divider()
        Button("Forget Light…", systemImage: "trash", role: .destructive) { confirmForget() }
    }

    private func confirmForget() {
        let alert = NSAlert()
        alert.messageText = "Forget “\(light.name)”?"
        alert.informativeText = "It's removed from groups and scenes and won't be added again when it's found. You can bring it back from Settings › Lights."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { store.forget(light) }
    }
}

import LucenteKit
import SwiftUI

/// Shared header: big swatch, name (double-click or ✎ to rename), status line, power switch.
private struct DetailHeader<Subtitle: View>: View {
    var state: LightState
    var name: String
    var canRename: Bool
    var hasPower: Bool
    var onRename: @MainActor (String) -> Void
    var onPower: @MainActor (Bool) -> Void
    @ViewBuilder var subtitle: Subtitle

    @State private var draft = ""
    @State private var renaming = false
    @FocusState private var editing: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Swatch(state: state, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                if renaming {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.title.weight(.semibold))
                        .focused($editing)
                        .onSubmit(commit)
                        .onExitCommand { renaming = false }
                        .onChange(of: editing) { _, focused in if !focused { commit() } }
                        .onAppear { DispatchQueue.main.async { editing = true } }
                } else {
                    HStack(spacing: 6) {
                        Text(name).font(.title.weight(.semibold))
                        if canRename {
                            Button("Rename", systemImage: "pencil", action: startRenaming)
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Rename")
                        }
                    }
                    .onTapGesture(count: 2) { if canRename { startRenaming() } }
                }
                subtitle
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasPower {
                // A closure literal, not `set: onPower`: passing the function value makes Xcode 26.6
                // crash emitting its @isolated(any) thunk in optimized Intel builds.
                Toggle("Power", isOn: Binding(get: { state.power == true }, set: { onPower($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .labelsHidden()
            }
        }
    }

    private func startRenaming() {
        draft = name
        renaming = true
    }

    private func commit() {
        guard renaming else { return }
        renaming = false
        if draft != name { onRename(draft) }
    }
}

struct LightDetail: View {
    @Environment(LightStore.self) private var store
    let light: Light

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DetailHeader(
                    state: light.state, name: light.name, canRename: true,
                    hasPower: light.capabilities.contains(.power),
                    onRename: { store.rename(light, to: $0) },
                    onPower: { store.send(.power($0), to: light) }
                ) {
                    HStack(spacing: 6) {
                        Text("\(light.driver.vendor) \(light.kind.title.lowercased())")
                        Text("·")
                        StatusBadge(light: light)
                        if let rssi = light.rssi, light.isReachable {
                            Text("·")
                            Text("\(rssi) dBm").monospacedDigit()
                        }
                    }
                }

                ControlPanel(target: ControlTarget(
                    capabilities: light.capabilities, state: light.state, effects: light.effects,
                    send: { store.send($0, to: light) }
                ))

                if !light.readsState {
                    Label("This light can't report its state, so Lucente shows what it last sent.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let error = light.lastError, !light.isConnected {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(light.name)
        .navigationSubtitle(light.advertisedName ?? "")
        .toolbar {
            ToolbarItem {
                Button("Identify", systemImage: "sparkles") { Task { await store.identify(light) } }
                    .help("Blink this light so you can tell which one it is")
            }
            ToolbarItem {
                Menu("More", systemImage: "ellipsis.circle") { LightMenu(light: light) }
            }
        }
    }
}

struct StatusBadge: View {
    let light: Light

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(light.statusText)
        }
    }

    private var color: Color {
        switch light.connection {
        case .connected: .green
        case .connecting where light.isReachable: .orange
        default: light.isReachable ? .yellow : .secondary
        }
    }
}

struct GroupDetail: View {
    @Environment(LightStore.self) private var store
    let group: LightGroup
    var edit: () -> Void

    var body: some View {
        let members = store.members(of: group)
        let caps = store.capabilities(of: group)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DetailHeader(
                    state: store.state(of: group), name: group.name, canRename: true,
                    hasPower: caps.contains(.power),
                    onRename: { name in
                        var renamed = group
                        renamed.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? group.name : name
                        store.update(renamed)
                    },
                    onPower: { store.send(.power($0), to: group) }
                ) {
                    Text("\(members.filter(\.isReachable).count) of \(members.count) lights available")
                }

                if caps.subtracting([.power]).isEmpty {
                    Text(caps.isEmpty ? "These lights share no controls." : "This group only switches its lights on and off.")
                        .foregroundStyle(.secondary)
                } else {
                    ControlPanel(target: ControlTarget(
                        capabilities: caps, state: store.state(of: group), effects: store.effects(of: group),
                        send: { store.send($0, to: group) }
                    ))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Members").font(.headline)
                    ForEach(members) { light in
                        LightRow(light: light)
                        if light.id != members.last?.id { Divider() }
                    }
                }
                .padding(14)
                .background(.background.secondary, in: .rect(cornerRadius: 12))
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(group.name)
        .toolbar {
            ToolbarItem {
                Button("Edit Group", systemImage: "slider.horizontal.3", action: edit)
            }
        }
    }
}

struct SceneDetail: View {
    @Environment(LightStore.self) private var store
    let scene: LightScene

    var body: some View {
        let entries = scene.states.compactMap { id, state in store.light(id).map { ($0, state) } }
            .sorted { $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    SceneSwatches(scene: scene).scaleEffect(3).frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scene.name).font(.title.weight(.semibold))
                        Text("\(entries.count) lights").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apply Scene") { store.apply(scene) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries, id: \.0.id) { light, state in
                        HStack(spacing: 10) {
                            Swatch(state: state, size: 14)
                            Text(light.name)
                            Spacer()
                            Text(describe(state, effects: light.effects)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if light.id != entries.last?.0.id { Divider() }
                    }
                }
                .padding(14)
                .background(.background.secondary, in: .rect(cornerRadius: 12))

                HStack {
                    Button("Update to Current Look") { store.recapture(scene.id) }
                    Spacer()
                    Button("Delete Scene", role: .destructive) { store.deleteScene(scene.id) }
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(scene.name)
    }
}

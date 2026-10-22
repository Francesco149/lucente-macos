import LucenteKit
import SwiftUI

enum SidebarItem: Hashable, Codable {
    case light(UUID), group(UUID), scene(UUID)
}

extension FocusedValues {
    @Entry var sidebarSelection: SidebarItem?
    @Entry var mainWindowActions: MainWindowActions?
}

/// Actions the menu bar commands trigger in the main window.
struct MainWindowActions {
    var newGroup: () -> Void
    var saveScene: () -> Void
}

struct MainView: View {
    @Environment(LightStore.self) private var store
    @AppStorage(Preferences.showInMenuBar) private var showInMenuBar = true
    @SceneStorage("selection") private var storedSelection: Data?
    @State private var selection: SidebarItem?
    @State private var groupDraft: GroupDraft?
    @State private var savingScene = false
    @State private var sceneName = ""

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection, groupDraft: $groupDraft, savingScene: $savingScene)
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 380)
        } detail: {
            detail
                .frame(minWidth: 420)
        }
        .safeAreaInset(edge: .top, spacing: 0) { BluetoothBanner() }
        .toolbar { toolbar }
        .sheet(item: $groupDraft) { draft in
            GroupEditor(draft: draft) { saved in
                if let id = saved { selection = .group(id) }
            }
        }
        .alert("Save Scene", isPresented: $savingScene) {
            TextField("Name", text: $sceneName)
            Button("Save") {
                let name = sceneName.trimmingCharacters(in: .whitespaces)
                let scene = store.saveScene(named: name.isEmpty ? "Scene \(store.scenes.count + 1)" : name)
                selection = .scene(scene.id)
                sceneName = ""
            }
            Button("Cancel", role: .cancel) { sceneName = "" }
        } message: {
            Text("Captures how every light looks right now, so you can bring it back with one click.")
        }
        .focusedSceneValue(\.sidebarSelection, selection)
        .focusedSceneValue(\.mainWindowActions, MainWindowActions(
            newGroup: { groupDraft = GroupDraft(store: store) },
            saveScene: { savingScene = true }
        ))
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            if let data = storedSelection { selection = try? JSONDecoder().decode(SidebarItem.self, from: data) }
        }
        .onDisappear {
            // Living in the menu bar: drop the Dock icon while no window is open.
            if showInMenuBar { NSApp.setActivationPolicy(.accessory) }
        }
        .onChange(of: selection) { _, new in
            storedSelection = new.flatMap { try? JSONEncoder().encode($0) }
            if case .light(let id)? = new, let light = store.light(id) { store.connect(light) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .light(let id)?:
            if let light = store.light(id) { LightDetail(light: light).id(id) } else { placeholder }
        case .group(let id)?:
            if let group = store.group(id) {
                GroupDetail(group: group, edit: { groupDraft = GroupDraft(store: store, editing: group) }).id(id)
            } else { placeholder }
        case .scene(let id)?:
            if let scene = store.scene(id) { SceneDetail(scene: scene).id(id) } else { placeholder }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label(store.lights.isEmpty ? "Looking for Lights…" : "No Selection", systemImage: "lightbulb.led.wide")
        } description: {
            Text(store.lights.isEmpty
                ? "Switch your strips and bars on nearby. They appear in the sidebar as soon as they're found."
                : "Choose a light, group or scene in the sidebar.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.setAllPower(!store.anyOn)
            } label: {
                Label(store.anyOn ? "All Off" : "All On", systemImage: store.anyOn ? "power.circle.fill" : "power.circle")
            }
            .help(store.anyOn ? "Turn every light off" : "Turn every light on")
            .disabled(store.lights.isEmpty)

            Menu {
                Button("New Group…", systemImage: "rectangle.3.group") { groupDraft = GroupDraft(store: store) }
                    .disabled(store.lights.isEmpty)
                Button("Save Scene…", systemImage: "camera.filters") { savingScene = true }
                    .disabled(store.lights.isEmpty)
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Create a group or save a scene")
        }
    }
}

/// Explains why nothing works when Bluetooth is off or not permitted.
struct BluetoothBanner: View {
    @Environment(LightStore.self) private var store

    var body: some View {
        if let message {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).font(.callout)
                Spacer()
                if store.availability == .unauthorized {
                    Button("Open Privacy Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                    }
                } else if store.availability == .poweredOff {
                    Button("Open Bluetooth Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var message: LocalizedStringKey? {
        switch store.availability {
        case .poweredOff: "Bluetooth is off — turn it on to control your lights."
        case .unauthorized: "Lucente isn't allowed to use Bluetooth."
        case .unsupported: "This Mac doesn't support Bluetooth Low Energy."
        case .resetting: "Bluetooth is restarting…"
        case .ready, .unknown: nil
        }
    }
}

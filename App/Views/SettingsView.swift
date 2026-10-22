import LucenteKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Lights", systemImage: "lightbulb.led.wide") { LightsSettings() }
            Tab("Advanced", systemImage: "wrench.and.screwdriver") { AdvancedSettings() }
        }
        .scenePadding()
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(LightStore.self) private var store
    @AppStorage(Preferences.showInMenuBar) private var showInMenuBar = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show in menu bar", isOn: $showInMenuBar)
                Text("With the menu bar item on, Lucente keeps running after you close its window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Stay connected to lights", isOn: $store.stayConnected)
                Text("Keeps a link to every light so controls respond instantly and strips report changes made with their remote. Off: connect on demand and let go after two idle minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Turn lights off when the Mac sleeps", isOn: $store.followSystemSleep)
                Text("Lights that were on come back on when the Mac wakes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct LightsSettings: View {
    @Environment(LightStore.self) private var store

    var body: some View {
        Form {
            Section("Known Lights") {
                if store.lights.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(store.lights) { light in
                    LabeledContent {
                        HStack {
                            Text(light.statusText).foregroundStyle(.secondary)
                            Menu("Actions", systemImage: "ellipsis.circle") { LightMenu(light: light) }
                                .menuStyle(.borderlessButton)
                                .labelStyle(.iconOnly)
                                .fixedSize()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Swatch(state: light.state, size: 12)
                            VStack(alignment: .leading) {
                                Text(light.name)
                                Text("\(light.driver.vendor) · \(light.advertisedName ?? light.id.uuidString)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !store.ignored.isEmpty {
                Section("Forgotten Lights") {
                    ForEach(store.ignored, id: \.self) { id in
                        LabeledContent(id.uuidString) {
                            Button("Restore") { store.unignore(id) }
                        }
                        .font(.caption.monospaced())
                    }
                    Text("Restored lights reappear the next time they advertise.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 320)
    }
}

private struct AdvancedSettings: View {
    @Environment(LightStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                LabeledContent("Bluetooth", value: String(describing: store.availability))
                LabeledContent("Lights connected", value: "\(store.lights.filter(\.isConnected).count) of \(store.lights.count)")
            }
            Section {
                Button("Show Bluetooth Traffic") { openWindow(id: WindowID.traffic) }
                Button("Reconnect All Lights") { store.refresh() }
                Button("Reveal Data File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.storageURL])
                }
            } footer: {
                Text("The traffic window shows every byte sent to and received from your lights — useful for diagnosing a light that ignores commands.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

import LucenteKit
import SwiftUI

/// The Lights menu. Selection-aware commands act on whatever is selected in the sidebar.
struct LucenteCommands: Commands {
    let store: LightStore
    @FocusedValue(\.sidebarSelection) private var selection
    @FocusedValue(\.mainWindowActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Group…") { actions?.newGroup() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil || store.lights.isEmpty)
            Button("Save Scene…") { actions?.saveScene() }
                .keyboardShortcut("s")
                .disabled(actions == nil || store.lights.isEmpty)
        }

        CommandMenu("Lights") {
            Button("Toggle Power") { togglePower() }
                .keyboardShortcut("t")
                .disabled(targets.isEmpty)
            Button("Brighter") { adjustBrightness(by: 10) }
                .keyboardShortcut("=")
                .disabled(targets.isEmpty)
            Button("Dimmer") { adjustBrightness(by: -10) }
                .keyboardShortcut("-")
                .disabled(targets.isEmpty)
            Button("Identify") {
                if case .light(let id)? = selection, let light = store.light(id) { Task { await store.identify(light) } }
            }
            .keyboardShortcut("i")
            .disabled(!isLightSelected)

            Divider()

            Button("Turn All On") { store.setAllPower(true) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Turn All Off") { store.setAllPower(false) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])

            Divider()

            Menu("Apply Scene") {
                ForEach(Array(store.scenes.enumerated()), id: \.element.id) { index, scene in
                    if index < 9 {
                        Button(scene.name) { store.apply(scene) }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    } else {
                        Button(scene.name) { store.apply(scene) }
                    }
                }
            }
            .disabled(store.scenes.isEmpty)

            Divider()

            Button("Reconnect All") { store.refresh() }
                .keyboardShortcut("r")
        }
    }

    private var isLightSelected: Bool {
        if case .light? = selection { true } else { false }
    }

    /// The lights the selection refers to (a scene selects nothing to drive).
    private var targets: [Light] {
        switch selection {
        case .light(let id)?: store.light(id).map { [$0] } ?? []
        case .group(let id)?: store.group(id).map(store.members(of:)) ?? []
        default: []
        }
    }

    private func togglePower() {
        let on = !targets.contains { $0.state.power == true }
        store.setPower(on, for: targets)
    }

    private func adjustBrightness(by delta: Int) {
        for light in targets where light.capabilities.contains(.brightness) {
            store.send(.brightness(((light.state.brightness ?? 100) + delta).clamped(to: 1...100)), to: light)
        }
    }
}

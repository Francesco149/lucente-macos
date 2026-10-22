import LucenteKit
import SwiftUI

/// Whatever the control panel drives: a single light or a group.
struct ControlTarget {
    var capabilities: Set<Capability>
    var state: LightState
    var effects: [Effect]
    var send: (LightCommand) -> Void
}

/// Color / white / effect controls plus brightness, shown only for what the target supports.
struct ControlPanel: View {
    var target: ControlTarget

    @State private var tab: LightMode = .color

    private var tabs: [LightMode] {
        var tabs: [LightMode] = []
        if target.capabilities.contains(.color) { tabs.append(.color) }
        if target.capabilities.contains(.white) { tabs.append(.white) }
        if target.capabilities.contains(.effect), !target.effects.isEmpty { tabs.append(.effect) }
        return tabs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if tabs.count > 1 {
                Picker("Mode", selection: $tab) {
                    ForEach(tabs, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: tab) { _, new in switchMode(to: new) }
            }

            Group {
                switch tab {
                case .color where tabs.contains(.color): colorControls
                case .white where tabs.contains(.white): whiteControls
                case .effect where tabs.contains(.effect): effectControls
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if target.capabilities.contains(.brightness) {
                LevelSlider(title: "Brightness", value: target.state.brightness) { target.send(.brightness($0)) }
            }
        }
        .onAppear { tab = preferredTab }
        .onChange(of: target.state.mode) { _, _ in tab = preferredTab }
    }

    private var preferredTab: LightMode {
        if let mode = target.state.mode, tabs.contains(mode) { return mode }
        return tabs.first ?? .color
    }

    /// Picking a tab applies that mode right away (an effect waits until one is chosen).
    private func switchMode(to mode: LightMode) {
        guard mode != target.state.mode else { return }
        switch mode {
        case .color: target.send(.color(target.state.color ?? .white))
        case .white: target.send(.white(target.state.white ?? 100))
        case .effect: break
        }
    }

    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            ColorWheel(color: target.state.color) { target.send(.color($0)) }
                .frame(maxWidth: 260, maxHeight: 260)
                .frame(maxWidth: .infinity)
            HStack {
                ColorPresets(selected: target.state.color) { target.send(.color($0)) }
                Spacer()
                ColorPicker("More Colors", selection: systemColor, supportsOpacity: false)
                    .labelsHidden()
                    .help("Open the system color picker")
            }
        }
    }

    /// Bridges the system color panel. Picked colors are normalized to full brightness, since
    /// brightness is controlled separately.
    private var systemColor: Binding<Color> {
        Binding(
            get: { Color(target.state.color ?? .white) },
            set: { color in
                if let rgb = RGB(color), rgb != RGB(0, 0, 0) { target.send(.color(rgb.normalized)) }
            }
        )
    }

    private var whiteControls: some View {
        LevelSlider(title: "White", value: target.state.white, minimumSymbol: "circle.lefthalf.filled", maximumSymbol: "sun.max") {
            target.send(.white($0))
        }
    }

    private var effectControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                ForEach(target.effects) { effect in
                    let button = Button {
                        target.send(.effect(id: effect.id, speed: target.state.speed))
                    } label: {
                        Text(effect.name)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    if target.state.mode == .effect && target.state.effect == effect.id {
                        button.buttonStyle(.borderedProminent) // the running effect
                    } else {
                        button.buttonStyle(.bordered)
                    }
                }
            }
            if target.capabilities.contains(.speed) {
                LevelSlider(title: "Speed", value: target.state.speed, minimumSymbol: "tortoise", maximumSymbol: "hare") { speed in
                    if let effect = target.state.effect, target.state.mode == .effect {
                        target.send(.effect(id: effect, speed: speed))
                    }
                }
            }
        }
    }
}

extension LightMode {
    var title: LocalizedStringKey {
        switch self {
        case .color: "Color"
        case .white: "White"
        case .effect: "Effects"
        }
    }

    var symbol: String {
        switch self {
        case .color: "paintpalette"
        case .white: "sun.max"
        case .effect: "sparkles"
        }
    }
}

import LucenteKit
import SwiftUI

/// The menu bar extra: every light and group at a glance, scenes one click away.
struct MenuBarPanel: View {
    @Environment(LightStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Lucente").font(.headline)
                Spacer()
                PowerToggle(isOn: store.anyOn) { store.setAllPower($0) }
                    .controlSize(.small)
                    .disabled(store.lights.isEmpty)
                    .help("All lights")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if store.lights.isEmpty {
                        Text(store.availability == .ready ? "Looking for lights…" : "Bluetooth isn't available.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    if !store.groups.isEmpty {
                        PanelHeading("Groups")
                        ForEach(store.groups) { group in
                            PanelRow(
                                state: store.state(of: group), name: group.name,
                                capabilities: store.capabilities(of: group), available: true,
                                send: { store.send($0, to: group) }
                            )
                        }
                    }
                    if !store.lights.isEmpty {
                        PanelHeading("Lights")
                        ForEach(store.lights) { light in
                            PanelRow(
                                state: light.state, name: light.name, capabilities: light.capabilities,
                                available: light.isReachable, send: { store.send($0, to: light) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)

            if !store.scenes.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    PanelHeading("Scenes")
                    FlowLayout(spacing: 6) {
                        ForEach(store.scenes) { scene in
                            Button(scene.name) { store.apply(scene) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }

            Divider()

            HStack(spacing: 12) {
                Button("Open Lucente") {
                    openWindow(id: WindowID.main)
                    NSApp.activate()
                }
                Spacer()
                Button {
                    openSettings()
                    NSApp.activate()
                } label: { Image(systemName: "gearshape") }
                    .help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .help("Quit Lucente")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 320)
    }
}

private struct PanelHeading: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }
}

private struct PanelRow: View {
    var state: LightState
    var name: String
    var capabilities: Set<Capability>
    var available: Bool
    var send: (LightCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Swatch(state: state, size: 10)
                Text(name).lineLimit(1)
                Spacer()
                if capabilities.contains(.power) {
                    PowerToggle(isOn: state.power == true) { send(.power($0)) }
                }
            }
            if capabilities.contains(.brightness), state.power == true {
                CompactSlider(value: state.brightness ?? 100) { send(.brightness($0)) }
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 3)
        .opacity(available ? 1 : 0.5)
    }
}

/// A small brightness slider that doesn't fight live updates while dragging.
private struct CompactSlider: View {
    var value: Int
    var onChange: (Int) -> Void
    @State private var local = 100.0
    @State private var editing = false

    var body: some View {
        Slider(value: $local, in: 1...100, onEditingChanged: { editing = $0 })
            .controlSize(.mini)
            .onAppear { local = Double(value) }
            .onChange(of: value) { _, new in if !editing { local = Double(new) } }
            .onChange(of: local) { _, new in if Int(new.rounded()) != value { onChange(Int(new.rounded())) } }
    }
}

/// Wraps scene buttons onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var current: [Int] = [], x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.isEmpty, x + size.width > width {
                rows.append((current, y, x - spacing, height))
                y += height + spacing
                current = []; x = 0; height = 0
            }
            current.append(index)
            x += size.width + spacing
            height = max(height, size.height)
        }
        if !current.isEmpty { rows.append((current, y, x - spacing, height)) }
        return rows
    }
}

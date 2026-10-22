import AppKit
import LucenteKit
import SwiftUI

extension Color {
    init(_ rgb: RGB) {
        self.init(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }

    /// The warm white the white channel produces, for previews.
    static let warmWhite = Color(.sRGB, red: 1, green: 0.86, blue: 0.68)

    static let spectrum: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
        Color(hue: $0, saturation: 1, brightness: 1)
    }
}

extension RGB {
    init?(_ color: Color) {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(
            UInt8((c.redComponent * 255).rounded().clamped(to: 0...255)),
            UInt8((c.greenComponent * 255).rounded().clamped(to: 0...255)),
            UInt8((c.blueComponent * 255).rounded().clamped(to: 0...255))
        )
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

/// A light's current look as a glowing dot: its color, warm white, a spectrum for effects, or
/// dark when off.
struct Swatch: View {
    var state: LightState
    var size: CGFloat = 14

    private var isOn: Bool { state.power != false }

    var body: some View {
        Circle()
            .fill(fill)
            .opacity(isOn ? 0.6 + 0.4 * Double(state.brightness ?? 100) / 100 : 1)
            .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
            .frame(width: size, height: size)
            .shadow(color: isOn ? glow.opacity(0.55) : .clear, radius: size / 3)
            .animation(.easeOut(duration: 0.2), value: state)
    }

    private var fill: AnyShapeStyle {
        guard isOn else { return AnyShapeStyle(Color.secondary.opacity(0.25)) }
        switch state.mode {
        case .effect?: return AnyShapeStyle(AngularGradient(colors: Color.spectrum, center: .center))
        case .white?: return AnyShapeStyle(Color.warmWhite)
        default: return AnyShapeStyle(state.color.map(Color.init) ?? Color.secondary.opacity(0.4))
        }
    }

    private var glow: Color {
        switch state.mode {
        case .effect?: .pink
        case .white?: .warmWhite
        default: state.color.map(Color.init) ?? .clear
        }
    }
}

/// A slider that reports every change while dragging, but doesn't let incoming state updates
/// yank the thumb out from under the pointer. Labels get a fixed column so stacked sliders
/// (white, speed, brightness) share one track width.
struct LevelSlider: View {
    static let labelWidth: CGFloat = 84

    var title: LocalizedStringKey
    var value: Int?
    var range: ClosedRange<Double> = 0...100
    var minimumSymbol = "sun.min"
    var maximumSymbol = "sun.max.fill"
    var onChange: (Int) -> Void

    @State private var local: Double = 100
    @State private var editing = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: minimumSymbol).foregroundStyle(.secondary).frame(width: 18)
                Slider(value: $local, in: range, onEditingChanged: { editing = $0 })
                    // Anything that disagrees with the model came from the user (drag, click,
                    // keyboard or VoiceOver); model updates set `local` to the same value.
                    .onChange(of: local) { _, new in
                        if Int(new.rounded()) != value { onChange(Int(new.rounded())) }
                    }
                Image(systemName: maximumSymbol).foregroundStyle(.secondary).frame(width: 18)
                Text("\(Int(local.rounded()))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .onAppear { local = Double(value ?? 100) }
        .onChange(of: value) { _, new in if !editing, let new { local = Double(new) } }
    }
}

/// Hue/saturation disc. Dragging reports full-brightness colors; brightness is its own slider.
struct ColorWheel: View {
    var color: RGB?
    var onChange: (RGB) -> Void

    @State private var dragging: RGB?

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let radius = side / 2
            let shown = dragging ?? color
            ZStack {
                Circle().fill(AngularGradient(colors: Color.spectrum, center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
                Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 1)
                if let shown {
                    Circle()
                        .fill(Color(shown))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .position(knob(for: shown, radius: radius))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { pick($0.location, radius: radius) }
                    .onEnded { _ in dragging = nil }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Color")
        .accessibilityValue(color?.hex ?? "none")
    }

    private func knob(for rgb: RGB, radius: CGFloat) -> CGPoint {
        let (hue, saturation, _) = rgb.hsv
        let angle = hue * .pi / 180
        return CGPoint(x: radius + cos(angle) * saturation * radius, y: radius + sin(angle) * saturation * radius)
    }

    private func pick(_ point: CGPoint, radius: CGFloat) {
        let dx = point.x - radius, dy = point.y - radius
        var hue = atan2(dy, dx) * 180 / .pi
        if hue < 0 { hue += 360 }
        let rgb = RGB(hue: hue, saturation: min(hypot(dx, dy) / radius, 1))
        guard rgb != dragging else { return }
        dragging = rgb
        onChange(rgb)
    }
}

/// A one-tap palette of common colors.
struct ColorPresets: View {
    var selected: RGB?
    var onPick: (RGB) -> Void

    static let colors: [RGB] = [
        RGB(255, 0, 0), RGB(255, 80, 0), RGB(255, 170, 0), RGB(255, 255, 0), RGB(0, 255, 60),
        RGB(0, 255, 200), RGB(0, 120, 255), RGB(70, 0, 255), RGB(180, 0, 255), RGB(255, 0, 140),
        RGB(255, 255, 255),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.colors, id: \.self) { rgb in
                Button { onPick(rgb) } label: {
                    Circle()
                        .fill(Color(rgb))
                        .overlay(Circle().strokeBorder(.primary.opacity(rgb == selected ? 0.8 : 0.15), lineWidth: rgb == selected ? 2 : 0.5))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(rgb.hex)
            }
        }
    }
}

/// The name of a color in the vocabulary people actually use for lights.
func describe(_ state: LightState, effects: [Effect]) -> String {
    guard state.power != false else { return "Off" }
    let level = state.brightness.map { " · \($0)%" } ?? ""
    switch state.mode {
    case .effect?:
        return (effects.first { $0.id == state.effect }?.name ?? "Effect") + level
    case .white?:
        return "White \(state.white ?? 100)%" + level
    default:
        guard let color = state.color else { return state.power == true ? "On" : "Unknown" }
        return color.hex + level
    }
}

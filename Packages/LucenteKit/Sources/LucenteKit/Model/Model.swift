import Foundation

// The vendor-neutral model. Nothing here knows about device bytes — drivers translate between
// these types and the wire, and everything above the driver layer speaks only these.

/// A control a light exposes. The UI shows only what a light has; a group offers only what all
/// of its members share.
public enum Capability: String, Codable, CaseIterable, Hashable, Sendable {
    case power, color, brightness, white, effect, speed

    public var title: String {
        switch self {
        case .power: "Power"
        case .color: "Color"
        case .brightness: "Brightness"
        case .white: "White"
        case .effect: "Effects"
        case .speed: "Effect speed"
        }
    }
}

/// An 8-bit-per-channel color. In `LightState` this is the *logical* hue at full brightness;
/// brightness is tracked separately and drivers combine the two as their wire format requires.
public struct RGB: Codable, Hashable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let white = RGB(255, 255, 255)

    /// From hue (degrees), saturation and value (0...1).
    public init(hue: Double, saturation: Double, value: Double = 1) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let c = value * saturation
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c
        let (r, g, b): (Double, Double, Double) = switch h {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        self.init(UInt8.clamped((r + m) * 255), UInt8.clamped((g + m) * 255), UInt8.clamped((b + m) * 255))
    }

    /// Hue in degrees, saturation and value in 0...1.
    public var hsv: (hue: Double, saturation: Double, value: Double) {
        let r = Double(self.r) / 255, g = Double(self.g) / 255, b = Double(self.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    /// Scale every channel by `percent`/100.
    public func scaled(by percent: Int) -> RGB {
        let f = Double(percent) / 100
        return RGB(.clamped(Double(r) * f), .clamped(Double(g) * f), .clamped(Double(b) * f))
    }

    /// Stretch to full brightness (the inverse of `scaled`): the brightest channel becomes 255.
    public var normalized: RGB {
        let mx = max(r, g, b)
        guard mx > 0 else { return RGB(0, 0, 0) }
        let f = 255 / Double(mx)
        return RGB(.clamped(Double(r) * f), .clamped(Double(g) * f), .clamped(Double(b) * f))
    }

    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }
}

/// What a light is showing. Static color, warm/white channel, or a built-in effect.
public enum LightMode: String, Codable, Hashable, Sendable {
    case color, white, effect
}

/// Live (or last-known) state in common units; `nil` means unknown. For write-only devices this
/// is optimistic — what we last sent — and is persisted so the app reopens where you left off.
public struct LightState: Codable, Hashable, Sendable {
    public var power: Bool?
    public var mode: LightMode?
    /// Full-brightness hue for `.color` mode.
    public var color: RGB?
    /// Master level, 0–100.
    public var brightness: Int?
    /// White/warm channel level, 0–100, for `.white` mode.
    public var white: Int?
    /// Active effect id for `.effect` mode (driver-specific).
    public var effect: Int?
    /// Effect speed, 0–100, higher is faster.
    public var speed: Int?

    public init(
        power: Bool? = nil, mode: LightMode? = nil, color: RGB? = nil, brightness: Int? = nil,
        white: Int? = nil, effect: Int? = nil, speed: Int? = nil
    ) {
        self.power = power
        self.mode = mode
        self.color = color
        self.brightness = brightness
        self.white = white
        self.effect = effect
        self.speed = speed
    }
}

/// A user intent, in common units. Drivers encode these to bytes.
public enum LightCommand: Hashable, Sendable {
    case power(Bool)
    case color(RGB)
    case brightness(Int)
    case white(Int)
    case effect(id: Int, speed: Int?)

    public var capability: Capability {
        switch self {
        case .power: .power
        case .color: .color
        case .brightness: .brightness
        case .white: .white
        case .effect: .effect
        }
    }
}

/// A built-in animation a light can run.
public struct Effect: Identifiable, Hashable, Sendable {
    public let id: Int
    public let name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// A normalized BLE advertisement — what drivers see when deciding whether a device is theirs.
public struct Advertisement: Hashable, Sendable {
    public var name: String?
    /// 16-bit UUIDs in uppercase short form ("AF30") or full 128-bit strings.
    public var serviceUUIDs: [String]
    /// Company identifier → payload (company id bytes stripped).
    public var manufacturerData: [UInt16: [UInt8]]
    public var rssi: Int?

    public init(
        name: String? = nil, serviceUUIDs: [String] = [], manufacturerData: [UInt16: [UInt8]] = [:],
        rssi: Int? = nil
    ) {
        self.name = name
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerData = manufacturerData
        self.rssi = rssi
    }

    /// Split raw CoreBluetooth manufacturer data (little-endian company id + payload).
    public static func manufacturerData(fromRaw raw: [UInt8]) -> [UInt16: [UInt8]] {
        guard raw.count >= 2 else { return [:] }
        return [UInt16(raw[0]) | UInt16(raw[1]) << 8: Array(raw.dropFirst(2))]
    }

    public func advertises(service short: String) -> Bool {
        serviceUUIDs.contains { $0.caseInsensitiveCompare(short) == .orderedSame || $0.lowercased().hasPrefix("0000\(short.lowercased())-") }
    }
}

extension UInt8 {
    static func clamped(_ v: Double) -> UInt8 { UInt8(Swift.max(0, Swift.min(255, v.rounded()))) }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.max(lo, Swift.min(hi, self)) }
}

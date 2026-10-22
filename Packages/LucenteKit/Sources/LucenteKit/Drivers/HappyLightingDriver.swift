import Foundation

/// HappyLighting / Triones / LEDBLE / Consmart RGB(W) strips (Android app `com.qh.blelight`).
///
/// Protocol spec and evidence: docs/protocols/happylighting.md. Highlights:
/// - Write `FFD9` (in service `FFD5`), notify `FFD4` (in service `FFD0`).
/// - Brightness is not a wire field: each channel of the `56` color command is pre-scaled, so we
///   keep a logical hue plus a level and bake them together on send, and un-scale on read-back.
/// - Default password 1234 → `CF 01 02 03 04 FC`, sent after notifications are enabled.
/// - Status query `EF 01 77` → 12-byte `66 …` notification.
public struct HappyLightingDriver: LightDriver {
    public static let id = "happylighting"

    /// Advertised-name prefixes the vendor app claims (its `COMPANY_NAME` scan regex).
    static let namePrefixes = [
        "triones", "brglight", "color+", "color-", "dream", "light-", "qhm", "flash", "ld-",
        "dimmer", "morimoto", "thaillamp", "lxdz", "archaic", "glowdriv", "ramand", "qlamp",
    ]

    /// Mode byte → name, in the vendor app's order (0x63 is reserved and omitted).
    static let modes: [Effect] = [
        Effect(id: 0x25, name: "Rainbow fade"), Effect(id: 0x26, name: "Red fade"),
        Effect(id: 0x27, name: "Green fade"), Effect(id: 0x28, name: "Blue fade"),
        Effect(id: 0x29, name: "Yellow fade"), Effect(id: 0x2A, name: "Cyan fade"),
        Effect(id: 0x2B, name: "Purple fade"), Effect(id: 0x2C, name: "White fade"),
        Effect(id: 0x2D, name: "Red/green fade"), Effect(id: 0x2E, name: "Red/blue fade"),
        Effect(id: 0x2F, name: "Green/blue fade"), Effect(id: 0x30, name: "Rainbow flash"),
        Effect(id: 0x31, name: "Red flash"), Effect(id: 0x32, name: "Green flash"),
        Effect(id: 0x33, name: "Blue flash"), Effect(id: 0x34, name: "Yellow flash"),
        Effect(id: 0x35, name: "Cyan flash"), Effect(id: 0x36, name: "Purple flash"),
        Effect(id: 0x37, name: "White flash"), Effect(id: 0x38, name: "Rainbow jump"),
        Effect(id: 0x61, name: "RGB fade"), Effect(id: 0x62, name: "RGB jump"),
    ]

    static let query = Frame([0xEF, 0x01, 0x77])
    static let defaultPassword = Frame([0xCF, 0x01, 0x02, 0x03, 0x04, 0xFC])

    public init() {}
    public init?(config: [String: Int]) { self.init() }

    public static func match(_ advertisement: Advertisement) -> Self? {
        guard let name = advertisement.name?.lowercased(),
              namePrefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
        return Self()
    }

    public var config: [String: Int] { [:] }
    public var vendor: String { "HappyLighting" }
    public var kind: LightKind { .strip }
    public var capabilities: Set<Capability> { [.power, .color, .brightness, .white, .effect, .speed] }
    public var readsState: Bool { true }
    public var profile: GATTProfile { GATTProfile(services: ["FFD5", "FFD0"], write: "FFD9", notify: "FFD4") }
    public var effects: [Effect] { Self.modes }

    public func connectFrames(at date: Date) -> [Frame] { [Self.query, Self.defaultPassword] }

    /// Re-querying status keeps the link warm and picks up changes made by a remote or another app.
    public func keepaliveFrame(at date: Date) -> Frame? { Self.query }

    public func defaultName(advertisedName: String?, id: UUID) -> String {
        // "Triones:0882A400033E" → "Strip 033E": the MAC tail is printed on the controller.
        if let name = advertisedName, let colon = name.lastIndex(of: ":") {
            let mac = name[name.index(after: colon)...]
            if mac.count >= 4 { return "Strip \(mac.suffix(4))" }
        }
        return "Strip \(id.uuidString.suffix(4))"
    }

    // MARK: Encoding

    public func encode(_ command: LightCommand, state: LightState) -> Encoded {
        var s = state
        switch command {
        case .power(let on):
            s.power = on
            return Encoded([Frame([0xCC, on ? 0x23 : 0x24, 0x33], slot: .power)], s)

        case .color(let rgb):
            s.mode = .color
            s.color = rgb
            return Encoded([Self.colorFrame(rgb, brightness: s.brightness ?? 100)], s)

        case .brightness(let level):
            let level = level.clamped(0, 100)
            s.brightness = level
            switch s.mode {
            case .white: return Encoded([Self.whiteFrame(s.white ?? 100, brightness: level)], s)
            case .effect: return Encoded([], s) // `BB` effects have no level; keep it for later
            case .color, nil: return Encoded([Self.colorFrame(s.color ?? .white, brightness: level)], s)
            }

        case .white(let level):
            let level = level.clamped(0, 100)
            s.mode = .white
            s.white = level
            return Encoded([Self.whiteFrame(level, brightness: s.brightness ?? 100)], s)

        case .effect(let id, let speed):
            let speed = (speed ?? s.speed ?? 50).clamped(0, 100)
            s.mode = .effect
            s.effect = id
            s.speed = speed
            return Encoded([Frame([0xBB, UInt8(truncatingIfNeeded: id), Self.wireSpeed(speed), 0x44], slot: .effect)], s)
        }
    }

    /// `56 R G B 00 F0 AA` with channels pre-scaled by brightness (floored at 3%, like the app).
    static func colorFrame(_ rgb: RGB, brightness: Int) -> Frame {
        let c = rgb.scaled(by: max(brightness, 3))
        return Frame([0x56, c.r, c.g, c.b, 0x00, 0xF0, 0xAA], slot: .color)
    }

    /// `56 00 00 00 WW 0F AA` — the `0F` flag selects the white channel.
    static func whiteFrame(_ level: Int, brightness: Int) -> Frame {
        let ww = UInt8.clamped(Double(level * brightness) / 10_000 * 255)
        return Frame([0x56, 0x00, 0x00, 0x00, ww, 0x0F, 0xAA], slot: .color)
    }

    /// UI speed is 0–100 (faster is higher); the wire is 1–31 (lower is faster).
    static func wireSpeed(_ percent: Int) -> UInt8 {
        UInt8((31 - Double(percent) * 30 / 100).rounded().clampedTo(1, 31))
    }

    static func uiSpeed(_ wire: UInt8) -> Int {
        Int((Double(31 - Int(wire).clamped(1, 31)) / 30 * 100).rounded())
    }

    // MARK: Read-back

    /// Parse the 12-byte `66` status packet: `66 type power mode flags speed R G B W ver tail`.
    public func parse(notification bytes: [UInt8], state: LightState) -> LightState? {
        guard bytes.count >= 12, bytes[0] == 0x66 else { return nil }
        var s = state
        s.power = bytes[2] == 0x23
        let modeByte = Int(bytes[3])
        let rgb = RGB(bytes[6], bytes[7], bytes[8])
        let w = Int(bytes[9])
        let peak = Int(max(rgb.r, rgb.g, rgb.b))

        if Self.modes.contains(where: { $0.id == modeByte }) {
            s.mode = .effect
            s.effect = modeByte
            s.speed = Self.uiSpeed(bytes[5])
        } else if peak == 0, w > 0 {
            // The device reports level × white combined; split it back the way we sent it.
            let reported = Int((Double(w) / 255 * 100).rounded())
            let level = state.mode == .white ? max(state.brightness ?? 100, 1) : 100
            let white = Int((Double(reported) * 100 / Double(level)).rounded())
            s.mode = .white
            if white <= 100 {
                s.white = white
                s.brightness = level
            } else {
                s.white = reported
                s.brightness = 100
            }
        } else {
            s.mode = .color
            if peak > 0 { s.color = rgb.normalized }
            s.brightness = Int((Double(peak) / 255 * 100).rounded())
        }
        return s
    }
}

extension Double {
    func clampedTo(_ lo: Double, _ hi: Double) -> Double { Swift.max(lo, Swift.min(hi, self)) }
}

import Foundation

/// Raingel LED bars — a rebrand of the DoHome/"DoIt" app (`am.doit.dohome.strip`).
///
/// Protocol spec and evidence: docs/protocols/raingel.md. Highlights:
/// - Identified by advertised service `AF30` and/or manufacturer id `0x5958` ("XY"), whose two
///   payload bytes are `[group, type]` — the capability set, known before connecting.
/// - GATT service `AE30`, write `AE01` (write-without-response only). No auth, no checksum.
/// - Write-only: there is no status packet, so state is optimistic (what we last sent).
/// - Commands are `[opcode][args]`: power `01`, brightness `02`, color/white `03`, effect `07`,
///   clock `08`.
/// - The bars are dual-mode (BR/EDR + LE) radios; see docs/bars-investigation.md for why that
///   matters on Linux. CoreBluetooth always connects them over LE.
public struct RaingelDriver: LightDriver {
    public static let id = "raingel"
    public static let manufacturerID: UInt16 = 0x5958

    // DeviceGroup (manufacturer byte 0) → capability predicates (StripDevice.java).
    static let rgbGroups: Set<Int> = [3, 4, 5, 6, 16]
    static let cctGroups: Set<Int> = [2, 5, 6, 16]
    static let whiteGroups: Set<Int> = [4, 6, 16]

    /// Best-effort `07` presets (variant A): id, name, p2, color count, palette bytes.
    static let presets: [(effect: Effect, p2: UInt8, colors: UInt8, palette: [UInt8])] = [
        (Effect(id: 1, name: "7-color fade"), 0, 8, [0x01, 0x23, 0x45, 0x67]),
        (Effect(id: 2, name: "7-color jump"), 0, 8, [0x01, 0x23, 0x45, 0x67]),
        (Effect(id: 3, name: "6-color fade"), 0, 6, [0x01, 0x23, 0x45]),
        (Effect(id: 4, name: "2-color fade"), 0, 4, [0x01, 0x23]),
        (Effect(id: 5, name: "Single-color sweep"), 0, 2, [0x67]),
    ]

    public var group: Int?
    public var deviceType: Int?

    public init(group: Int? = nil, deviceType: Int? = nil) {
        self.group = group
        self.deviceType = deviceType
    }

    public init?(config: [String: Int]) {
        self.init(group: config["group"], deviceType: config["type"])
    }

    public static func match(_ advertisement: Advertisement) -> Self? {
        let mfg = advertisement.manufacturerData[manufacturerID]
        guard mfg != nil || advertisement.advertises(service: "AF30") else { return nil }
        if let mfg, mfg.count >= 2 { return Self(group: Int(mfg[0]), deviceType: Int(mfg[1])) }
        return Self()
    }

    public var config: [String: Int] {
        var c: [String: Int] = [:]
        c["group"] = group
        c["type"] = deviceType
        return c
    }

    public var vendor: String { "Raingel" }
    public var kind: LightKind { .bar }
    public var readsState: Bool { false }
    public var profile: GATTProfile { GATTProfile(services: ["AE30"], write: "AE01") }

    public var capabilities: Set<Capability> {
        var caps: Set<Capability> = [.power, .brightness]
        guard let group else { return caps.union([.color, .white, .effect]) } // unknown: assume full
        if Self.rgbGroups.contains(group) { caps.formUnion([.color, .effect]) }
        if Self.cctGroups.contains(group) || Self.whiteGroups.contains(group) { caps.insert(.white) }
        return caps
    }

    public var effects: [Effect] {
        capabilities.contains(.effect) ? Self.presets.map(\.effect) : []
    }

    /// The vendor app's only connect-time write is a clock sync (for on-device timers).
    public func connectFrames(at date: Date) -> [Frame] { [Self.clockFrame(date)] }

    /// None needed: a bar holds an idle CoreBluetooth link indefinitely, and re-asserting power
    /// (what the Linux app did) would undo a change made with the IR remote.
    public func keepaliveFrame(at date: Date) -> Frame? { nil }

    public func encode(_ command: LightCommand, state: LightState) -> Encoded {
        var s = state
        switch command {
        case .power(let on):
            s.power = on
            return Encoded([Frame([0x01, on ? 0x01 : 0x00], slot: .power)], s)

        case .brightness(let level):
            let level = level.clamped(0, 100)
            s.brightness = level
            // Effects carry their own level byte, so re-send the running effect instead.
            if s.mode == .effect, let id = s.effect, let frame = Self.effectFrame(id, brightness: level) {
                return Encoded([frame], s)
            }
            return Encoded([Frame([0x02, UInt8(level)], slot: .level)], s)

        case .color(let rgb):
            s.mode = .color
            s.color = rgb
            return Encoded([Frame([0x03, rgb.r, rgb.g, rgb.b, 0x00, 0x00, 0x00], slot: .color)], s)

        case .white(let level):
            let level = level.clamped(0, 100)
            s.mode = .white
            s.white = level
            return Encoded([Frame([0x03, 0x00, 0x00, 0x00, 0x00, UInt8(level), 0x01], slot: .color)], s)

        case .effect(let id, _):
            guard let frame = Self.effectFrame(id, brightness: s.brightness ?? 100) else { return Encoded([], s) }
            s.mode = .effect
            s.effect = id
            return Encoded([frame], s)
        }
    }

    public func parse(notification: [UInt8], state: LightState) -> LightState? { nil }

    /// `07 id p2 level colorCount palette…`
    static func effectFrame(_ id: Int, brightness: Int) -> Frame? {
        guard let p = presets.first(where: { $0.effect.id == id }) else { return nil }
        return Frame([0x07, UInt8(id), p.p2, UInt8(brightness.clamped(0, 100)), p.colors] + p.palette, slot: .effect)
    }

    /// `08 01 00 00 00 yearLo yearHi month day hour minute second`
    static func clockFrame(_ date: Date, calendar: Calendar = .current) -> Frame {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 2026
        return Frame([
            0x08, 0x01, 0x00, 0x00, 0x00, UInt8(year & 0xFF), UInt8(year >> 8 & 0xFF),
            UInt8(c.month ?? 1), UInt8(c.day ?? 1), UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0),
        ])
    }
}

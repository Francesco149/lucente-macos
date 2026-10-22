import Foundation

/// One BLE write produced by a driver.
public struct Frame: Hashable, Sendable {
    /// Frames that share a slot supersede each other while still queued, so dragging a color
    /// wheel sends the latest color rather than a backlog. `nil` frames (handshakes, queries)
    /// are always sent.
    public enum Slot: Hashable, Sendable {
        case power, color, level, effect
    }

    public var bytes: [UInt8]
    public var slot: Slot?

    public init(_ bytes: [UInt8], slot: Slot? = nil) {
        self.bytes = bytes
        self.slot = slot
    }
}

/// Which GATT services/characteristics a driver talks to (16-bit UUID strings, e.g. "FFD9").
public struct GATTProfile: Hashable, Sendable {
    public var services: [String]
    public var write: String
    public var notify: String?

    public init(services: [String], write: String, notify: String? = nil) {
        self.services = services
        self.write = write
        self.notify = notify
    }
}

/// The result of encoding a command: bytes to send plus the state they leave the light in.
public struct Encoded: Sendable {
    public var frames: [Frame]
    public var state: LightState

    public init(_ frames: [Frame], _ state: LightState) {
        self.frames = frames
        self.state = state
    }
}

/// The physical form factor, used for icons and default names.
public enum LightKind: String, Sendable {
    case strip, bar

    public var title: String {
        switch self {
        case .strip: "Strip"
        case .bar: "Bar"
        }
    }

    public var symbolName: String {
        switch self {
        case .strip: "light.strip.2"
        case .bar: "lightbulb.led.wide"
        }
    }
}

/// The single extension point for new vendors: a driver is the only place that knows device
/// bytes. It identifies its devices from an advertisement, encodes common commands into GATT
/// writes and (if the device reports state) parses notifications back into common state.
///
/// Drivers are pure values — no I/O — so every encoder is unit-testable. Adding a vendor is one
/// new file plus a line in `DriverRegistry`.
public protocol LightDriver: Sendable {
    /// Stable identifier, persisted with each known light.
    static var id: String { get }
    /// Claim a scanned device, or return nil if it isn't ours.
    static func match(_ advertisement: Advertisement) -> Self?
    /// Rebuild from the per-device config persisted by `config`.
    init?(config: [String: Int])

    var config: [String: Int] { get }
    var vendor: String { get }
    var kind: LightKind { get }
    var capabilities: Set<Capability> { get }
    /// True when the device reports its state back (otherwise state is optimistic).
    var readsState: Bool { get }
    var profile: GATTProfile { get }
    var effects: [Effect] { get }

    /// Writes to send right after connecting (auth, status query, clock sync…).
    func connectFrames(at date: Date) -> [Frame]
    /// Periodic traffic while connected, or nil if the device needs none.
    func keepaliveFrame(at date: Date) -> Frame?
    func encode(_ command: LightCommand, state: LightState) -> Encoded
    /// Fold a notification into `state`, or nil if it isn't a status packet.
    func parse(notification: [UInt8], state: LightState) -> LightState?
    func defaultName(advertisedName: String?, id: UUID) -> String
}

extension LightDriver {
    public var driverID: String { Self.id }

    public func defaultName(advertisedName: String?, id: UUID) -> String {
        "\(kind.title) \(id.uuidString.suffix(4))"
    }
}

/// Maps advertisements and persisted records to drivers. Order matters only if two drivers
/// could claim the same device: specific signals (manufacturer id, service UUID) go first.
public enum DriverRegistry {
    public static var drivers: [any LightDriver.Type] {
        [RaingelDriver.self, HappyLightingDriver.self]
    }

    public static func identify(_ advertisement: Advertisement) -> (any LightDriver)? {
        for driver in drivers {
            if let match = driver.match(advertisement) { return match }
        }
        return nil
    }

    public static func restore(id: String, config: [String: Int]) -> (any LightDriver)? {
        drivers.first { $0.id == id }?.init(config: config)
    }
}

import CoreBluetooth
import Foundation
import Observation

public enum ConnectionStatus: Sendable, Equatable {
    case disconnected, connecting, connected
}

/// One known light: its driver, its last-known state, and its link status. Observable, so the
/// UI updates as state changes — whether from our own commands or the device's notifications.
@MainActor
@Observable
public final class Light: Identifiable {
    /// CoreBluetooth's per-Mac identifier for the peripheral (macOS doesn't expose MACs).
    public let id: UUID
    public internal(set) var driver: any LightDriver
    public internal(set) var advertisedName: String?
    public internal(set) var customName: String?
    public internal(set) var state: LightState
    public internal(set) var connection: ConnectionStatus = .disconnected
    public internal(set) var isReachable = false
    public internal(set) var rssi: Int?
    public internal(set) var lastError: String?

    @ObservationIgnored var lastSeen: Date?
    @ObservationIgnored var peripheral: CBPeripheral?
    @ObservationIgnored var link: PeripheralLink?
    @ObservationIgnored var pending: [(frame: Frame, at: Date)] = []
    @ObservationIgnored var connectStarted: Date?
    @ObservationIgnored var lastActivity = Date.distantPast

    init(id: UUID, driver: any LightDriver, advertisedName: String?, customName: String? = nil, state: LightState = .init()) {
        self.id = id
        self.driver = driver
        self.advertisedName = advertisedName
        self.customName = customName
        self.state = state
    }

    public var name: String { customName ?? defaultName }
    public var defaultName: String { driver.defaultName(advertisedName: advertisedName, id: id) }
    public var capabilities: Set<Capability> { driver.capabilities }
    public var effects: [Effect] { driver.effects }
    public var kind: LightKind { driver.kind }
    public var readsState: Bool { driver.readsState }
    public var isConnected: Bool { connection == .connected }

    /// One-line status for lists and menus.
    public var statusText: String {
        switch connection {
        case .connected: "Connected"
        case .connecting where isReachable: "Connecting…"
        default: isReachable ? "Available" : "Out of range"
        }
    }

    /// Buffer frames until the link is ready; coalesced like the link queue.
    func enqueuePending(_ frames: [Frame]) {
        for frame in frames {
            if let slot = frame.slot { pending.removeAll { $0.frame.slot == slot } }
            pending.append((frame, Date()))
        }
    }

    /// Hand buffered frames to the link, dropping any too stale to still reflect intent.
    func takePending(maxAge: TimeInterval) -> [Frame] {
        defer { pending.removeAll() }
        let cutoff = Date().addingTimeInterval(-maxAge)
        return pending.filter { $0.at >= cutoff }.map(\.frame)
    }
}

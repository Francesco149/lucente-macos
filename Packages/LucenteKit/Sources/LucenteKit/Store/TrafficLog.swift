import Foundation
import Observation
import os

enum Log {
    static let subsystem = "uk.headpats.lucente"
    static let ble = Logger(subsystem: subsystem, category: "ble")
    static let store = Logger(subsystem: subsystem, category: "store")
}

/// A ring buffer of recent Bluetooth traffic and connection events, shown in the app's Traffic
/// window — the first place to look when a light misbehaves. Mirrored to the unified log
/// (`make logs`) at debug level.
@MainActor
@Observable
public final class TrafficLog {
    public enum Direction: Sendable {
        case sent, received, event
    }

    public struct Entry: Identifiable, Sendable {
        public let id: Int
        public let date: Date
        public let light: String
        public let direction: Direction
        public let bytes: [UInt8]
        public let message: String

        public var hex: String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
    }

    public static let capacity = 1_000
    public private(set) var entries: [Entry] = []
    private var nextID = 0

    func record(_ direction: Direction, light: String, bytes: [UInt8] = [], _ message: String = "") {
        let entry = Entry(id: nextID, date: Date(), light: light, direction: direction, bytes: bytes, message: message)
        nextID += 1
        entries.append(entry)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        switch direction {
        case .sent: Log.ble.debug("→ \(light, privacy: .public) \(entry.hex, privacy: .public)")
        case .received: Log.ble.debug("← \(light, privacy: .public) \(entry.hex, privacy: .public)")
        case .event: Log.ble.info("\(light, privacy: .public): \(message, privacy: .public)")
        }
    }

    public func clear() { entries.removeAll() }
}

import Foundation

/// Several lights controlled together through the controls they all share.
public struct LightGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var members: [UUID]
    /// The controls the user chose to gang together (e.g. power only). The group offers the
    /// intersection of this with what every member supports.
    public var controls: Set<Capability>

    public init(id: UUID = UUID(), name: String, members: [UUID], controls: Set<Capability>) {
        self.id = id
        self.name = name
        self.members = members
        self.controls = controls
    }
}

/// A saved look: each light's state, re-applied together.
public struct LightScene: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var states: [UUID: LightState]

    public init(id: UUID = UUID(), name: String, states: [UUID: LightState]) {
        self.id = id
        self.name = name
        self.states = states
    }

    /// The commands that reproduce `state`. A light that should be off only gets switched off;
    /// otherwise power comes first, since some controllers ignore color while they're off.
    static func commands(for state: LightState, capabilities: Set<Capability>) -> [LightCommand] {
        if state.power == false { return capabilities.contains(.power) ? [.power(false)] : [] }
        var commands: [LightCommand] = state.power == true ? [.power(true)] : []
        switch state.mode {
        case .color?: if let c = state.color { commands.append(.color(c)) }
        case .white?: if let w = state.white { commands.append(.white(w)) }
        case .effect?: if let e = state.effect { commands.append(.effect(id: e, speed: state.speed)) }
        case nil: if let c = state.color { commands.append(.color(c)) }
        }
        if let b = state.brightness { commands.append(.brightness(b)) }
        return commands.filter { capabilities.contains($0.capability) }
    }
}

/// What the app persists between launches.
struct StoredState: Codable {
    struct StoredLight: Codable {
        var id: UUID
        var driver: String
        var config: [String: Int]
        var advertisedName: String?
        var customName: String?
        var state: LightState
    }

    var version = 1
    var lights: [StoredLight] = []
    var groups: [LightGroup] = []
    var scenes: [LightScene] = []
    var ignored: [UUID] = []
    var stayConnected = true
    var followSystemSleep = false
}

/// JSON file persistence with atomic writes.
struct Storage: Sendable {
    let url: URL

    static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(components: "Lucente", "state.json")
    }

    func load() -> StoredState {
        guard let data = try? Data(contentsOf: url) else { return StoredState() }
        do {
            return try JSONDecoder().decode(StoredState.self, from: data)
        } catch {
            // Keep the unreadable file for inspection instead of silently overwriting it.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            Log.store.error("Unreadable state file, starting fresh: \(error.localizedDescription, privacy: .public)")
            return StoredState()
        }
    }

    func save(_ state: StoredState) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
        } catch {
            Log.store.error("Saving state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

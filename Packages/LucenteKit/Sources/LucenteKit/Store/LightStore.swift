import CoreBluetooth
import Foundation
import Observation

/// The app's model: known lights, groups and scenes, plus discovery, connections, command
/// dispatch and persistence. The UI binds to it directly; everything here runs on the main actor.
///
/// Connections are opportunistic. A command to a light that isn't connected is buffered and a
/// connect is issued; CoreBluetooth completes it when the light next advertises, and the buffer
/// (minus anything stale) is flushed. With "stay connected" on, every known light gets a standing
/// connect request, so control is instant and drops heal themselves.
@MainActor
@Observable
public final class LightStore {
    public private(set) var lights: [Light] = []
    public private(set) var groups: [LightGroup] = []
    public private(set) var scenes: [LightScene] = []
    /// Lights the user removed; they aren't re-added when they advertise again.
    public private(set) var ignored: [UUID] = []
    public private(set) var availability: BluetoothAvailability = .unknown
    public let traffic = TrafficLog()

    /// Hold a connection to every known light (instant control, live read-back).
    public var stayConnected: Bool {
        didSet { stayConnectedChanged() }
    }

    /// Turn lights off when the Mac sleeps and back on when it wakes.
    public var followSystemSleep: Bool {
        didSet { scheduleSave() }
    }

    private let central = BluetoothCentral()
    private let storage: Storage
    @ObservationIgnored private var started = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var beats = 0
    @ObservationIgnored private var switchedOffForSleep: [UUID] = []

    static let reachableWindow: TimeInterval = 30
    static let pendingMaxAge: TimeInterval = 20
    static let onDemandTimeout: TimeInterval = 15
    static let idleDisconnect: TimeInterval = 120

    public init(storageURL: URL? = nil) {
        storage = Storage(url: storageURL ?? Storage.defaultURL)
        let stored = storage.load()
        stayConnected = stored.stayConnected
        followSystemSleep = stored.followSystemSleep
        groups = stored.groups
        scenes = stored.scenes
        ignored = stored.ignored
        lights = stored.lights.compactMap { record in
            guard let driver = DriverRegistry.restore(id: record.driver, config: record.config) else { return nil }
            return Light(
                id: record.id, driver: driver, advertisedName: record.advertisedName,
                customName: record.customName, state: record.state
            )
        }
        sortLights()
    }

    public var storageURL: URL { storage.url }

    /// Start Bluetooth (this is what triggers the permission prompt) and the housekeeping loop.
    public func start() {
        guard !started else { return }
        started = true
        central.onAvailabilityChange = { [weak self] in self?.availabilityChanged($0) }
        central.onDiscover = { [weak self] in self?.discovered($0, $1) }
        central.onConnect = { [weak self] in self?.connected($0) }
        central.onDisconnect = { [weak self] in self?.disconnected($0, error: $1) }
        central.activate()
        central.setScanning(true)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.tick()
            }
        }
    }

    // MARK: Lookup

    public func light(_ id: UUID) -> Light? { lights.first { $0.id == id } }
    public func group(_ id: UUID) -> LightGroup? { groups.first { $0.id == id } }
    public func scene(_ id: UUID) -> LightScene? { scenes.first { $0.id == id } }

    public var anyOn: Bool { lights.contains { $0.state.power == true } }

    // MARK: Commands

    /// Apply a command to one light: update its state optimistically and queue the bytes.
    /// Anything that changes what the light shows also switches it on.
    public func send(_ command: LightCommand, to light: Light) {
        guard light.capabilities.contains(command.capability) else { return }
        var frames: [Frame] = []
        var state = light.state
        if command.switchesOn, state.power != true, light.capabilities.contains(.power) {
            let on = light.driver.encode(.power(true), state: state)
            frames += on.frames
            state = on.state
        }
        let encoded = light.driver.encode(command, state: state)
        frames += encoded.frames
        if light.state != encoded.state { light.state = encoded.state }
        deliver(frames, to: light)
        scheduleSave()
    }

    public func send(_ command: LightCommand, to group: LightGroup) {
        guard capabilities(of: group).contains(command.capability) else { return }
        for light in members(of: group) { send(command, to: light) }
    }

    public func setPower(_ on: Bool, for lights: [Light]) {
        for light in lights { send(.power(on), to: light) }
    }

    public func setAllPower(_ on: Bool) { setPower(on, for: lights) }

    /// Send and wait (up to `timeout`) until the bytes have actually gone out — for Shortcuts,
    /// where the app may have just been launched and nothing is connected yet. Returns how many
    /// lights were reached.
    @discardableResult
    public func sendAndWait(_ command: LightCommand, to targets: [Light], timeout: Duration = .seconds(12)) async -> Int {
        for light in targets { send(command, to: light) }
        return await waitUntilDelivered(targets, timeout: timeout)
    }

    /// Wait until each light is connected with nothing left to send; returns how many are.
    @discardableResult
    public func waitUntilDelivered(_ targets: [Light], timeout: Duration = .seconds(12)) async -> Int {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !targets.allSatisfy(\.isDelivered) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return targets.filter(\.isDelivered).count
    }

    /// Blink a light twice so you can tell which one it is, leaving it as it was.
    public func identify(_ light: Light) async {
        guard light.capabilities.contains(.power), await waitUntilConnected(light) else { return }
        let original = light.state.power ?? true
        for on in [!original, original, !original, original] {
            deliver(light.driver.encode(.power(on), state: light.state).frames, to: light)
            try? await Task.sleep(for: .milliseconds(450))
        }
    }

    private func deliver(_ frames: [Frame], to light: Light) {
        guard !frames.isEmpty else { return }
        light.lastActivity = Date()
        if light.isConnected, let link = light.link {
            link.enqueue(frames)
        } else {
            light.enqueuePending(frames)
            connect(light)
        }
    }

    // MARK: Lights

    public func rename(_ light: Light, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        light.customName = trimmed.isEmpty || trimmed == light.defaultName ? nil : trimmed
        sortLights()
        scheduleSave()
    }

    /// Remove a light and stop it from reappearing; it's listed under ignored lights in Settings.
    public func forget(_ light: Light) {
        if let peripheral = light.peripheral { central.cancel(peripheral) }
        light.link = nil
        lights.removeAll { $0.id == light.id }
        ignored.append(light.id)
        for index in groups.indices { groups[index].members.removeAll { $0 == light.id } }
        for index in scenes.indices { scenes[index].states[light.id] = nil }
        scheduleSave()
    }

    public func unignore(_ id: UUID) {
        ignored.removeAll { $0 == id }
        scheduleSave()
    }

    public func connect(_ light: Light) {
        guard availability == .ready, light.connection == .disconnected else { return }
        guard let peripheral = light.peripheral ?? central.retrievePeripheral(light.id) else { return }
        light.peripheral = peripheral
        light.connection = .connecting
        light.connectStarted = Date()
        central.connect(peripheral)
    }

    /// Drop and re-establish the link — the "turn it off and on again" for a wedged light.
    public func reconnect(_ light: Light) {
        traffic.record(.event, light: light.name, "Reconnecting")
        if let peripheral = light.peripheral, light.connection != .disconnected {
            central.cancel(peripheral) // `disconnected` reconnects when staying connected
            if !stayConnected { Task { try? await Task.sleep(for: .milliseconds(300)); connect(light) } }
        } else {
            connect(light)
        }
    }

    /// Restart discovery and chase every light that isn't connected.
    public func refresh() {
        central.setScanning(false)
        central.setScanning(true)
        for light in lights where light.connection == .disconnected && (stayConnected || light.isReachable) {
            connect(light)
        }
    }

    private func waitUntilConnected(_ light: Light, timeout: Duration = .seconds(10)) async -> Bool {
        connect(light)
        let deadline = ContinuousClock.now + timeout
        while !light.isConnected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return light.isConnected
    }

    private func sortLights() {
        lights.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Groups

    public func members(of group: LightGroup) -> [Light] { group.members.compactMap(light) }

    /// The controls a group offers: what the user ganged, limited to what every member has.
    /// Effect ids are vendor-specific, so mixed-vendor groups don't offer effects.
    public func capabilities(of group: LightGroup) -> Set<Capability> {
        let members = members(of: group)
        guard !members.isEmpty else { return [] }
        var caps = members.reduce(group.controls) { $0.intersection($1.capabilities) }
        if Set(members.map(\.driver.driverID)).count > 1 { caps.subtract([.effect, .speed]) }
        return caps
    }

    public func effects(of group: LightGroup) -> [Effect] {
        capabilities(of: group).contains(.effect) ? members(of: group).first?.effects ?? [] : []
    }

    /// A representative state for the group's controls: on if any member is on, otherwise the
    /// first member's values (members usually agree, since they're driven together).
    public func state(of group: LightGroup) -> LightState {
        let members = members(of: group)
        var state = members.first?.state ?? LightState()
        state.power = members.contains { $0.state.power == true }
        return state
    }

    @discardableResult
    public func createGroup(name: String, members: [UUID], controls: Set<Capability>) -> LightGroup {
        let group = LightGroup(name: name, members: members, controls: controls)
        groups.append(group)
        scheduleSave()
        return group
    }

    public func update(_ group: LightGroup) {
        guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index] = group
        scheduleSave()
    }

    public func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: Scenes

    /// Snapshot every light whose state is known.
    @discardableResult
    public func saveScene(named name: String) -> LightScene {
        let scene = LightScene(name: name, states: currentStates())
        scenes.append(scene)
        scheduleSave()
        return scene
    }

    public func recapture(_ id: UUID) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        scenes[index].states = currentStates()
        scheduleSave()
    }

    public func renameScene(_ id: UUID, to name: String) {
        guard let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        scenes[index].name = name
        scheduleSave()
    }

    public func deleteScene(_ id: UUID) {
        scenes.removeAll { $0.id == id }
        scheduleSave()
    }

    public func moveScenes(from source: IndexSet, to destination: Int) {
        // Same semantics as SwiftUI's `move(fromOffsets:toOffset:)`, without importing SwiftUI.
        let moving = source.map { scenes[$0] }
        var rest = scenes.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: moving, at: destination - source.count(in: 0..<destination))
        scenes = rest
        scheduleSave()
    }

    public func apply(_ scene: LightScene) {
        for (id, state) in scene.states {
            guard let light = light(id) else { continue }
            for command in LightScene.commands(for: state, capabilities: light.capabilities) {
                send(command, to: light)
            }
        }
    }

    private func currentStates() -> [UUID: LightState] {
        Dictionary(uniqueKeysWithValues: lights.filter { $0.state.power != nil }.map { ($0.id, $0.state) })
    }

    // MARK: System sleep

    public func systemWillSleep() {
        guard followSystemSleep else { return }
        let on = lights.filter { $0.state.power == true }
        switchedOffForSleep = on.map(\.id)
        setPower(false, for: on)
    }

    public func systemDidWake() {
        guard followSystemSleep else { return }
        setPower(true, for: switchedOffForSleep.compactMap(light))
        switchedOffForSleep = []
    }

    // MARK: Bluetooth events

    private func availabilityChanged(_ availability: BluetoothAvailability) {
        self.availability = availability
        traffic.record(.event, light: "Bluetooth", "\(availability)")
        guard availability == .ready else {
            for light in lights {
                light.link = nil
                light.connection = .disconnected
                light.isReachable = false
            }
            return
        }
        for light in lights {
            light.peripheral = central.retrievePeripheral(light.id) ?? light.peripheral
            // Commands sent before Bluetooth came up (e.g. a Shortcut that launched us) are waiting.
            if stayConnected || !light.pending.isEmpty { connect(light) }
        }
    }

    private func discovered(_ peripheral: CBPeripheral, _ advertisement: Advertisement) {
        let now = Date()
        if let light = self.light(peripheral.identifier) {
            light.peripheral = peripheral
            // Adverts arrive several times a second; only touch observed state when it matters.
            let stale = light.lastSeen.map { now.timeIntervalSince($0) > 2 } ?? true
            light.lastSeen = now
            if !light.isReachable {
                light.isReachable = true
                if stayConnected { connect(light) }
            }
            guard stale else { return }
            if let rssi = advertisement.rssi, abs((light.rssi ?? -200) - rssi) >= 4 { light.rssi = rssi }
            if let name = advertisement.name, light.advertisedName != name { light.advertisedName = name }
            // Pick up capability bytes for a light restored without them.
            if let fresh = DriverRegistry.identify(advertisement), fresh.driverID == light.driver.driverID,
               fresh.config != light.driver.config {
                light.driver = fresh
                scheduleSave()
            }
            return
        }
        guard !ignored.contains(peripheral.identifier), let driver = DriverRegistry.identify(advertisement) else { return }
        let light = Light(id: peripheral.identifier, driver: driver, advertisedName: advertisement.name)
        light.peripheral = peripheral
        light.lastSeen = now
        light.isReachable = true
        light.rssi = advertisement.rssi
        lights.append(light)
        sortLights()
        traffic.record(.event, light: light.name, "Discovered \(driver.vendor) \(driver.kind.title.lowercased())")
        scheduleSave()
        if stayConnected { connect(light) }
    }

    private func connected(_ peripheral: CBPeripheral) {
        guard let light = self.light(peripheral.identifier) else {
            central.cancel(peripheral)
            return
        }
        let link = PeripheralLink(peripheral: peripheral, profile: light.driver.profile)
        link.onWrite = { [weak self, weak light] bytes in
            guard let self, let light else { return }
            traffic.record(.sent, light: light.name, bytes: bytes)
        }
        link.onNotification = { [weak self, weak light] bytes in
            guard let self, let light else { return }
            received(bytes, from: light)
        }
        light.link = link
        Task {
            do {
                try await link.prepare()
                guard light.link === link else { return }
                light.connection = .connected
                light.isReachable = true
                light.lastError = nil
                light.lastActivity = Date()
                let mode = link.writeType == .withoutResponse ? "write without response" : "write with response"
                traffic.record(.event, light: light.name, "Connected (\(mode))")
                link.enqueue(light.driver.connectFrames(at: Date()) + light.takePending(maxAge: Self.pendingMaxAge))
            } catch {
                light.lastError = error.localizedDescription
                traffic.record(.event, light: light.name, "Setup failed: \(error.localizedDescription)")
                central.cancel(peripheral)
            }
        }
    }

    private func disconnected(_ peripheral: CBPeripheral, error: (any Error)?) {
        guard let light = self.light(peripheral.identifier) else { return }
        let wasConnected = light.connection == .connected
        light.link = nil
        light.connection = .disconnected
        if let error { light.lastError = error.localizedDescription }
        let reason = error.map { ": \($0.localizedDescription)" } ?? ""
        traffic.record(.event, light: light.name, (wasConnected ? "Disconnected" : "Connection ended") + reason)
        guard stayConnected, availability == .ready else { return }
        // A drop re-requests at once (it completes when the light advertises again); a failed
        // attempt waits a beat so a light that refuses us doesn't spin.
        Task {
            if !wasConnected { try? await Task.sleep(for: .seconds(3)) }
            if self.light(light.id) != nil { connect(light) }
        }
    }

    private func received(_ bytes: [UInt8], from light: Light) {
        traffic.record(.received, light: light.name, bytes: bytes)
        guard let state = light.driver.parse(notification: bytes, state: light.state), state != light.state else { return }
        light.state = state
        scheduleSave()
    }

    // MARK: Housekeeping

    private func tick() {
        beats += 1
        let now = Date()
        for light in lights {
            let recent = light.lastSeen.map { now.timeIntervalSince($0) < Self.reachableWindow } ?? false
            let reachable = light.isConnected || recent
            if light.isReachable != reachable { light.isReachable = reachable }

            if light.isConnected, beats % 4 == 0, let frame = light.driver.keepaliveFrame(at: now) {
                light.link?.enqueue([frame])
            }
            guard !stayConnected, let peripheral = light.peripheral else { continue }
            if light.connection == .connecting, let started = light.connectStarted,
               now.timeIntervalSince(started) > Self.onDemandTimeout {
                central.cancel(peripheral)
            } else if light.isConnected, now.timeIntervalSince(light.lastActivity) > Self.idleDisconnect,
                      light.link?.isIdle == true {
                central.cancel(peripheral)
            }
        }
    }

    private func stayConnectedChanged() {
        scheduleSave()
        if stayConnected {
            for light in lights { connect(light) }
        } else {
            // Drop standing requests for lights that aren't around; connected ones idle out.
            for light in lights where light.connection == .connecting {
                if let peripheral = light.peripheral { central.cancel(peripheral) }
            }
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Write state to disk immediately (call on quit).
    public func saveNow() {
        saveTask?.cancel()
        var stored = StoredState()
        stored.lights = lights.map {
            .init(
                id: $0.id, driver: $0.driver.driverID, config: $0.driver.config,
                advertisedName: $0.advertisedName, customName: $0.customName, state: $0.state
            )
        }
        stored.groups = groups
        stored.scenes = scenes
        stored.ignored = ignored
        stored.stayConnected = stayConnected
        stored.followSystemSleep = followSystemSleep
        storage.save(stored)
    }
}

extension Light {
    /// Connected with nothing left to send.
    var isDelivered: Bool { isConnected && pending.isEmpty && (link?.isIdle ?? false) }
}

extension LightCommand {
    var switchesOn: Bool {
        switch self {
        case .power: false
        case .brightness(let level): level > 0
        case .color, .white, .effect: true
        }
    }
}

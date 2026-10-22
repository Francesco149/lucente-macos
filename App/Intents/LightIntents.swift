import AppIntents
import LucenteKit

// Shortcuts, Siri and Spotlight actions. They run inside the app (launching it in the background
// if needed) and wait until the bytes actually reach the lights before reporting back.

/// A light, a group, or every light.
struct LightTargetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Light" }
    static var defaultQuery: LightTargetQuery { LightTargetQuery() }

    let id: String
    let name: String
    let kind: String
    let symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(kind)", image: .init(systemName: symbol))
    }

    static let everything = LightTargetEntity(id: "all", name: "All Lights", kind: "Everything", symbol: "lightbulb.2")

    @MainActor
    func lights(in store: LightStore) -> [Light] {
        if id == Self.everything.id { return store.lights }
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let uuid = UUID(uuidString: parts[1]) else { return [] }
        switch parts[0] {
        case "light": return store.light(uuid).map { [$0] } ?? []
        case "group": return store.group(uuid).map(store.members(of:)) ?? []
        default: return []
        }
    }
}

struct LightTargetQuery: EntityStringQuery {
    @Dependency private var store: LightStore

    @MainActor
    func entities(for identifiers: [String]) async throws -> [LightTargetEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [LightTargetEntity] {
        all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    @MainActor
    func suggestedEntities() async throws -> [LightTargetEntity] { all() }

    @MainActor
    private func all() -> [LightTargetEntity] {
        [LightTargetEntity.everything]
            + store.groups.map { LightTargetEntity(id: "group:\($0.id)", name: $0.name, kind: "Group", symbol: "rectangle.3.group") }
            + store.lights.map { LightTargetEntity(id: "light:\($0.id)", name: $0.name, kind: $0.kind.title, symbol: $0.kind.symbolName) }
    }
}

struct SceneEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Scene" }
    static var defaultQuery: SceneQuery { SceneQuery() }

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "camera.filters"))
    }
}

struct SceneQuery: EntityStringQuery {
    @Dependency private var store: LightStore

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SceneEntity] {
        store.scenes.filter { identifiers.contains($0.id) }.map { SceneEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SceneEntity] {
        store.scenes.filter { $0.name.localizedCaseInsensitiveContains(string) }.map { SceneEntity(id: $0.id, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [SceneEntity] {
        store.scenes.map { SceneEntity(id: $0.id, name: $0.name) }
    }
}

enum PowerAction: String, AppEnum {
    case on, off, toggle

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Power" }
    static var caseDisplayRepresentations: [PowerAction: DisplayRepresentation] {
        [.on: "On", .off: "Off", .toggle: "Toggle"]
    }
}

enum NamedColor: String, AppEnum {
    case red, orange, amber, yellow, green, teal, cyan, blue, indigo, purple, pink, white

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Color" }
    static var caseDisplayRepresentations: [NamedColor: DisplayRepresentation] {
        [
            .red: "Red", .orange: "Orange", .amber: "Amber", .yellow: "Yellow", .green: "Green", .teal: "Teal",
            .cyan: "Cyan", .blue: "Blue", .indigo: "Indigo", .purple: "Purple", .pink: "Pink", .white: "White",
        ]
    }

    var rgb: RGB {
        switch self {
        case .red: RGB(255, 0, 0)
        case .orange: RGB(255, 80, 0)
        case .amber: RGB(255, 150, 0)
        case .yellow: RGB(255, 230, 0)
        case .green: RGB(0, 255, 40)
        case .teal: RGB(0, 255, 160)
        case .cyan: RGB(0, 220, 255)
        case .blue: RGB(0, 60, 255)
        case .indigo: RGB(70, 0, 255)
        case .purple: RGB(170, 0, 255)
        case .pink: RGB(255, 0, 130)
        case .white: RGB(255, 255, 255)
        }
    }
}

enum LucenteIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unreachable(String)
    case unsupported(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unreachable(let name): "Couldn't reach \(name). Is it switched on and nearby?"
        case .unsupported(let name): "\(name) can't do that."
        }
    }
}

@MainActor
@discardableResult
private func run(_ command: LightCommand, on target: LightTargetEntity, store: LightStore) async throws -> Int {
    store.start()
    let lights = target.lights(in: store).filter { $0.capabilities.contains(command.capability) }
    guard !lights.isEmpty else { throw LucenteIntentError.unsupported(target.name) }
    let reached = await store.sendAndWait(command, to: lights)
    guard reached > 0 else { throw LucenteIntentError.unreachable(target.name) }
    return reached
}

struct SetPowerIntent: AppIntent {
    static var title: LocalizedStringResource { "Turn Lights On or Off" }
    static var description: IntentDescription { "Switches a light, a group or every light on, off, or the other way round." }

    @Parameter(title: "Light") var target: LightTargetEntity
    @Parameter(title: "Power", default: .toggle) var action: PowerAction
    @Dependency private var store: LightStore

    static var parameterSummary: some ParameterSummary { Summary("Turn \(\.$target) \(\.$action)") }

    init() {}
    init(target: LightTargetEntity, action: PowerAction) {
        self.target = target
        self.action = action
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let on = switch action {
        case .on: true
        case .off: false
        case .toggle: !target.lights(in: store).contains { $0.state.power == true }
        }
        try await run(.power(on), on: target, store: store)
        return .result(dialog: "Turned \(target.name) \(on ? "on" : "off").")
    }
}

struct SetColorIntent: AppIntent {
    static var title: LocalizedStringResource { "Set Light Color" }
    static var description: IntentDescription { "Sets a light or group to a color. A hex code such as #FF8000 overrides the named color." }

    @Parameter(title: "Light") var target: LightTargetEntity
    @Parameter(title: "Color", default: .white) var color: NamedColor
    @Parameter(title: "Hex Code") var hex: String?
    @Dependency private var store: LightStore

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$target) to \(\.$color)") { \.$hex }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rgb = hex.flatMap(RGB.init(hex:)) ?? color.rgb
        try await run(.color(rgb), on: target, store: store)
        return .result(dialog: "Set \(target.name) to \(hex.flatMap(RGB.init(hex:))?.hex ?? color.rawValue).")
    }
}

struct SetBrightnessIntent: AppIntent {
    static var title: LocalizedStringResource { "Set Light Brightness" }
    static var description: IntentDescription { "Sets how bright a light or group is, from 1 to 100%." }

    @Parameter(title: "Light") var target: LightTargetEntity
    @Parameter(title: "Brightness", default: 100, inclusiveRange: (1, 100)) var level: Int
    @Dependency private var store: LightStore

    static var parameterSummary: some ParameterSummary { Summary("Set \(\.$target) brightness to \(\.$level)%") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await run(.brightness(level), on: target, store: store)
        return .result(dialog: "Set \(target.name) to \(level)%.")
    }
}

struct ApplySceneIntent: AppIntent {
    static var title: LocalizedStringResource { "Apply Lighting Scene" }
    static var description: IntentDescription { "Brings back a scene saved in Lucente." }

    @Parameter(title: "Scene") var scene: SceneEntity
    @Dependency private var store: LightStore

    static var parameterSummary: some ParameterSummary { Summary("Apply \(\.$scene)") }

    init() {}
    init(scene: SceneEntity) { self.scene = scene }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        store.start()
        guard let saved = store.scene(scene.id) else { throw LucenteIntentError.unsupported(scene.name) }
        store.apply(saved)
        let lights = saved.states.keys.compactMap(store.light)
        let reached = await store.waitUntilDelivered(lights)
        guard reached > 0 || lights.isEmpty else { throw LucenteIntentError.unreachable(scene.name) }
        return .result(dialog: reached == lights.count ? "Applied \(scene.name)." : "Applied \(scene.name) to \(reached) of \(lights.count) lights.")
    }
}

struct AllLightsOffIntent: AppIntent {
    static var title: LocalizedStringResource { "Turn All Lights Off" }
    @Dependency private var store: LightStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await run(.power(false), on: .everything, store: store)
        return .result(dialog: "Lights off.")
    }
}

struct AllLightsOnIntent: AppIntent {
    static var title: LocalizedStringResource { "Turn All Lights On" }
    @Dependency private var store: LightStore

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await run(.power(true), on: .everything, store: store)
        return .result(dialog: "Lights on.")
    }
}

struct LucenteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ApplySceneIntent(),
            phrases: ["Apply \(\.$scene) in \(.applicationName)", "Set the \(\.$scene) scene in \(.applicationName)"],
            shortTitle: "Apply Scene",
            systemImageName: "camera.filters"
        )
        AppShortcut(
            intent: SetPowerIntent(),
            phrases: ["Toggle \(\.$target) in \(.applicationName)"],
            shortTitle: "Toggle Light",
            systemImageName: "power"
        )
        AppShortcut(
            intent: AllLightsOffIntent(),
            phrases: ["Turn off the lights in \(.applicationName)", "\(.applicationName) lights off"],
            shortTitle: "All Lights Off",
            systemImageName: "lightbulb.slash"
        )
        AppShortcut(
            intent: AllLightsOnIntent(),
            phrases: ["Turn on the lights in \(.applicationName)", "\(.applicationName) lights on"],
            shortTitle: "All Lights On",
            systemImageName: "lightbulb.led.fill"
        )
    }
}

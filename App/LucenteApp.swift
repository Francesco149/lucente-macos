import AppIntents
import LucenteKit
import SwiftUI

@main
struct LucenteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(Preferences.showInMenuBar) private var showInMenuBar = true

    private let store = AppServices.store

    init() {
        // Shortcuts/Siri intents run in this process and reach the store through @Dependency.
        let store = AppServices.store
        AppDependencyManager.shared.add(dependency: store)
    }

    var body: some Scene {
        Window("Lucente", id: WindowID.main) {
            MainView()
                .environment(store)
        }
        .defaultSize(width: 980, height: 660)
        .windowToolbarStyle(.unified)
        .commands { LucenteCommands(store: store) }

        MenuBarExtra("Lucente", systemImage: store.anyOn ? "lightbulb.led.fill" : "lightbulb.led", isInserted: $showInMenuBar) {
            MenuBarPanel()
                .environment(store)
        }
        .menuBarExtraStyle(.window)

        Window("Bluetooth Traffic", id: WindowID.traffic) {
            TrafficView()
                .environment(store)
        }
        .defaultSize(width: 760, height: 460)
        .keyboardShortcut("l", modifiers: [.command, .option])

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

/// Process-wide services. The store must exist before any scene or intent touches it.
@MainActor
enum AppServices {
    static let store = LightStore()
}

enum WindowID {
    static let main = "main"
    static let traffic = "traffic"
}

enum Preferences {
    static let showInMenuBar = "showInMenuBar"
}

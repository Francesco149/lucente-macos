import AppKit
import LucenteKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = AppServices.store
        store.start()

        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { store.systemWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { store.systemDidWake() }
            },
        ]

        // Launched at login: live in the menu bar instead of opening the window.
        if Self.launchedAsLoginItem, Self.menuBarEnabled {
            DispatchQueue.main.async {
                NSApp.windows.filter { $0.identifier?.rawValue == WindowID.main }.forEach { $0.close() }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// With the menu bar item on, closing the window keeps the app running there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Self.menuBarEnabled
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppServices.store.saveNow()
    }

    static var menuBarEnabled: Bool {
        UserDefaults.standard.object(forKey: Preferences.showInMenuBar) as? Bool ?? true
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

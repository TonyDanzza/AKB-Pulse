import AppKit
import SwiftUI

@main
struct AKBApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor: BatteryMonitor

    init() {
        Prefs.registerDefaults()
        let monitor = BatteryMonitor()
        _monitor = State(initialValue: monitor)
        monitor.start()
    }

    var body: some Scene {
        MenuBarExtra {
            StatusPopoverView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(monitor: monitor)
        }
    }
}

/// Делегат нужен ровно для двух вещей: убрать иконку из Dock (дублирует `LSUIElement`)
/// и поднять UNUserNotificationCenter до первого уведомления.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationService.shared.bootstrap()
    }
}

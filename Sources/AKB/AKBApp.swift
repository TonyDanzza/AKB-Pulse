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
        AppDelegate.monitor = monitor
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

    /// Монитор создаётся в `AKBApp.init`, до того как AppKit позовёт делегата.
    static var monitor: BatteryMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationService.shared.bootstrap()
        if let monitor = Self.monitor {
            OnboardingWindowController.shared.showIfNeeded(monitor: monitor)
        }
    }
}

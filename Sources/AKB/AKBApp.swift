import AppKit
import SwiftUI

@main
struct AKBApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var monitor: BatteryMonitor

    init() {
        Prefs.registerDefaults()
        // Шапка в файловом логе — первое, что увидит тот, кому пришлют отчёт (план §19.1).
        AKBLog.startSession()
        let monitor = BatteryMonitor()
        _monitor = State(initialValue: monitor)
        AppDelegate.monitor = monitor
        monitor.start()
    }

    var body: some Scene {
        // Строка меню живёт на AppKit (`StatusItemController`, план §20.1):
        // label `MenuBarExtra` не перерисовывался, пока popover закрыт.
        Settings {
            SettingsView(monitor: monitor)
        }
    }
}

/// Делегат убирает иконку из Dock (дублирует `LSUIElement`), поднимает
/// UNUserNotificationCenter до первого уведомления и владеет строкой меню.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Монитор создаётся в `AKBApp.init`, до того как AppKit позовёт делегата.
    static var monitor: BatteryMonitor?

    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationService.shared.bootstrap()
        if let monitor = Self.monitor {
            let controller = StatusItemController(monitor: monitor)
            controller.start()
            statusItem = controller
            OnboardingWindowController.shared.showIfNeeded(monitor: monitor)
        }
    }
}

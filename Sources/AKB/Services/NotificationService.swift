import Foundation
import UserNotifications

/// Системные уведомления о низком заряде (план §7).
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationService()

    private(set) var isAuthorized = false
    private var didRequest = false

    private override init() { super.init() }

    func bootstrap() {
        UNUserNotificationCenter.current().delegate = self
        requestAuthorizationIfNeeded()
    }

    func requestAuthorizationIfNeeded() {
        guard !didRequest else { return }
        didRequest = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.isAuthorized = granted }
        }
    }

    /// Показывает уведомление «iPhone почти разряжен».
    func postLowBattery(deviceName: String, percent: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.low.title",
                               defaultValue: "iPhone почти разряжен")
        content.body = String(format: String(localized: "notification.low.body",
                                             defaultValue: "%1$@: %2$d%%. Поставь на зарядку."),
                              deviceName, percent)
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // Показывать баннер, даже если приложение активно.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

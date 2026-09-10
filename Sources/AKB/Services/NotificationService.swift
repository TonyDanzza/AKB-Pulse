import Foundation
import UserNotifications

/// Системные уведомления: низкий заряд (план §7) и «отключи от зарядки» (план §7.5).
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
        guard Prefs.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.low.title",
                               defaultValue: "iPhone почти разряжен")
        content.body = String(format: String(localized: "notification.low.body",
                                             defaultValue: "%1$@: %2$d%%. Поставь на зарядку."),
                              deviceName, percent)
        content.sound = .default
        // Не срочное: time-sensitive пробивает «Не беспокоить», а разряженный
        // iPhone ночью подождёт до утра. Тишиной управляет фокус macOS,
        // как у остальных приложений.
        content.interruptionLevel = .active
        post(content)
    }

    /// Показывает уведомление «телефон дозарядился, можно отключить».
    /// Сто процентов и лимит зарядки — разные слова: у лимита «100 %» было бы враньём.
    func postChargeDone(deviceName: String, percent: Int) {
        guard Prefs.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        if percent >= 100 {
            content.title = String(localized: "notification.full.title",
                                   defaultValue: "iPhone заряжен полностью")
            content.body = String(format: String(localized: "notification.full.body",
                                                 defaultValue: "%1$@: 100 %%. Можно отключить от зарядки."),
                                  deviceName)
        } else {
            content.title = String(format: String(localized: "notification.limit.title",
                                                  defaultValue: "iPhone заряжен до %d %%"),
                                   percent)
            content.body = String(format: String(localized: "notification.limit.body",
                                                 defaultValue: "%1$@ дошёл до лимита зарядки. Можно отключить."),
                                  deviceName)
        }
        content.sound = .default
        // Не тревога: телефон в порядке, отключить провод можно и через минуту.
        content.interruptionLevel = .active
        post(content)
    }

    private func post(_ content: UNMutableNotificationContent) {
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

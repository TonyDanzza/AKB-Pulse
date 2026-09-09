import Foundation

/// Ключи и значения по умолчанию для `UserDefaults` / `@AppStorage`.
enum Prefs {

    enum Key {
        static let selectedUDID = "selectedUDID"
        static let pollInterval = "pollInterval"
        static let showPercent = "showPercent"
        static let notifyLowBattery = "notifyLowBattery"
        static let lowThreshold = "lowThreshold"
        static let repeatEveryTen = "repeatEveryTen"
        static let toolDirectory = "toolDirectory"
        static let launchAtLogin = "launchAtLogin"
    }

    /// Допустимые интервалы опроса (секунды).
    static let pollIntervals: [Int] = [30, 60, 120, 300]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.pollInterval: 60,
            Key.showPercent: true,
            Key.notifyLowBattery: true,
            Key.lowThreshold: 30,
            Key.repeatEveryTen: true,
            Key.launchAtLogin: false
        ])
    }

    static var selectedUDID: String? {
        get { UserDefaults.standard.string(forKey: Key.selectedUDID) }
        set { UserDefaults.standard.set(newValue, forKey: Key.selectedUDID) }
    }

    static var pollInterval: Int { UserDefaults.standard.integer(forKey: Key.pollInterval) }
    static var showPercent: Bool { UserDefaults.standard.bool(forKey: Key.showPercent) }
    static var notifyLowBattery: Bool { UserDefaults.standard.bool(forKey: Key.notifyLowBattery) }
    static var lowThreshold: Int { UserDefaults.standard.integer(forKey: Key.lowThreshold) }
    static var repeatEveryTen: Bool { UserDefaults.standard.bool(forKey: Key.repeatEveryTen) }
}

/// Отладочный режим из переменных окружения (план §9): `AKB_FAKE_PERCENT`, `AKB_FAKE_CHARGING`.
enum FakeMode {

    static var percent: Int? {
        guard let raw = ProcessInfo.processInfo.environment["AKB_FAKE_PERCENT"],
              let value = Int(raw) else { return nil }
        return min(max(value, 0), 100)
    }

    static var isCharging: Bool {
        let raw = ProcessInfo.processInfo.environment["AKB_FAKE_CHARGING"] ?? "0"
        return IMobileDeviceOutputParser.bool(raw)
    }

    /// Принудительно «инструмент не найден» — для снимка пустого состояния.
    static var forceToolMissing: Bool {
        IMobileDeviceOutputParser.bool(ProcessInfo.processInfo.environment["AKB_FAKE_NO_TOOL"])
    }

    /// Принудительно «телефон не найден».
    static var forceNoDevice: Bool {
        IMobileDeviceOutputParser.bool(ProcessInfo.processInfo.environment["AKB_FAKE_NO_DEVICE"])
    }

    static var isActive: Bool { percent != nil }
}

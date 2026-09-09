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
        static let launchAtLogin = "launchAtLogin"
        /// UDID → последний известный IPv4 телефона в локальной сети (план §16.3).
        static let lastKnownIP = "lastKnownIP"
        /// UDID → Wi-Fi MAC из записи сопряжения. По нему IP находится в `arp -an`.
        static let lastKnownMAC = "lastKnownMAC"
        /// UDID → имя и модель, чтобы показывать спящий телефон, которого нет в usbmuxd.
        static let deviceNames = "deviceNames"
        static let deviceProductTypes = "deviceProductTypes"
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

    // MARK: - Память об адресе телефона (фаза 4)

    private static func stringMap(_ key: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private static func setStringMap(_ value: [String: String], _ key: String) {
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    static var lastKnownIP: [String: String] {
        get { stringMap(Key.lastKnownIP) }
        set { setStringMap(newValue, Key.lastKnownIP) }
    }

    static var lastKnownMAC: [String: String] {
        get { stringMap(Key.lastKnownMAC) }
        set { setStringMap(newValue, Key.lastKnownMAC) }
    }

    static var deviceNames: [String: String] {
        get { stringMap(Key.deviceNames) }
        set { setStringMap(newValue, Key.deviceNames) }
    }

    static var deviceProductTypes: [String: String] {
        get { stringMap(Key.deviceProductTypes) }
        set { setStringMap(newValue, Key.deviceProductTypes) }
    }

    /// Запомнить телефон, чтобы показать его, когда usbmuxd его не видит.
    static func remember(_ device: PhoneDevice) {
        deviceNames[device.udid] = device.name
        if !device.productType.isEmpty { deviceProductTypes[device.udid] = device.productType }
    }

    /// Телефон, который приложение уже видело. Куда стучаться, разберётся
    /// `DeviceAddressResolver`: адрес он найдёт и по записи сопряжения с `arp`.
    static func cachedDevice(udid: String) -> PhoneDevice? {
        guard let name = deviceNames[udid] else { return nil }
        return PhoneDevice(udid: udid,
                           name: name,
                           productType: deviceProductTypes[udid] ?? "",
                           transport: .wifi)
    }
}

/// Отладочный режим из переменных окружения (план §9, §16.7):
/// `AKB_FAKE_PERCENT`, `AKB_FAKE_CHARGING`, `AKB_FAKE_STALE_AFTER`.
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

    /// Через сколько секунд после запуска фейковый телефон «засыпает»
    /// и начинает отвечать ошибкой — проверка состояния `.stale` (план §16.7).
    static var staleAfter: TimeInterval? {
        guard let raw = ProcessInfo.processInfo.environment["AKB_FAKE_STALE_AFTER"],
              let value = TimeInterval(raw), value >= 0 else { return nil }
        return value
    }

    /// Принудительно «телефон не найден».
    static var forceNoDevice: Bool {
        IMobileDeviceOutputParser.bool(ProcessInfo.processInfo.environment["AKB_FAKE_NO_DEVICE"])
    }

    static var isActive: Bool { percent != nil }
}

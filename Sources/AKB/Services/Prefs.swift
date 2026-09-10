import Foundation

/// Ключи и значения по умолчанию для `UserDefaults` / `@AppStorage`.
enum Prefs {

    enum Key {
        static let selectedUDID = "selectedUDID"
        static let pollInterval = "pollInterval"
        static let showPercent = "showPercent"
        /// Общий выключатель всех уведомлений (план §7.6).
        static let notificationsEnabled = "notificationsEnabled"
        static let notifyLowBattery = "notifyLowBattery"
        /// «Отключи от зарядки»: телефон дошёл до лимита или до 100 %.
        static let notifyChargeDone = "notifyChargeDone"
        static let lowThreshold = "lowThreshold"
        static let repeatEveryTen = "repeatEveryTen"
        static let launchAtLogin = "launchAtLogin"
        /// UDID → последний известный IPv4 телефона в локальной сети (план §16.3).
        static let lastKnownIP = "lastKnownIP"
        /// UDID → Wi-Fi MAC из записи сопряжения. По нему IP находится в `arp -an`.
        static let lastKnownMAC = "lastKnownMAC"
        /// UDID → имя хоста телефона (`iPhone-Toni.local.`): mDNS отвечает на него,
        /// даже когда телефон спит и пропал из usbmuxd (план §23.2).
        static let lastKnownHostname = "lastKnownHostname"
        /// UDID → когда по этому IP последний раз удалось прочитать заряд.
        /// Адрес забывается, только если он молчит дольше шести часов (план §23.1).
        static let ipConfirmedAt = "ipConfirmedAt"
        /// `arp` и маршрутная таблица пусты: похоже, не выдано разрешение
        /// «Локальная сеть». Подсказка в popover (план §23.2).
        static let localNetworkBlocked = "localNetworkBlocked"
        /// UDID → имя и модель, чтобы показывать спящий телефон, которого нет в usbmuxd.
        static let deviceNames = "deviceNames"
        static let deviceProductTypes = "deviceProductTypes"
        /// UDID → последнее прочитанное здоровье батареи, JSON (план §6.4).
        /// Оно меняется медленно, а при запуске телефон часто спит: показать
        /// вчерашние цифры с датой честнее, чем пустое место.
        static let batteryHealth = "batteryHealth"
        /// UDID → когда последний раз пробовали прочитать здоровье, успешно или нет.
        static let healthAttemptedAt = "healthAttemptedAt"
    }

    /// Допустимые интервалы опроса (секунды).
    static let pollIntervals: [Int] = [30, 60, 120, 300]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.pollInterval: 60,
            Key.showPercent: true,
            Key.notificationsEnabled: true,
            Key.notifyLowBattery: true,
            Key.notifyChargeDone: true,
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
    static var notificationsEnabled: Bool { UserDefaults.standard.bool(forKey: Key.notificationsEnabled) }
    static var notifyLowBattery: Bool { UserDefaults.standard.bool(forKey: Key.notifyLowBattery) }
    static var notifyChargeDone: Bool { UserDefaults.standard.bool(forKey: Key.notifyChargeDone) }
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

    static var lastKnownHostname: [String: String] {
        get { stringMap(Key.lastKnownHostname) }
        set { setStringMap(newValue, Key.lastKnownHostname) }
    }

    /// Когда адрес телефона последний раз подтвердился настоящим ответом.
    static var ipConfirmedAt: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: Key.ipConfirmedAt) as? [String: Double] ?? [:] }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: Key.ipConfirmedAt)
            } else {
                UserDefaults.standard.set(newValue, forKey: Key.ipConfirmedAt)
            }
        }
    }

    static var localNetworkBlocked: Bool {
        get { UserDefaults.standard.bool(forKey: Key.localNetworkBlocked) }
        set { UserDefaults.standard.set(newValue, forKey: Key.localNetworkBlocked) }
    }

    static var deviceNames: [String: String] {
        get { stringMap(Key.deviceNames) }
        set { setStringMap(newValue, Key.deviceNames) }
    }

    static var deviceProductTypes: [String: String] {
        get { stringMap(Key.deviceProductTypes) }
        set { setStringMap(newValue, Key.deviceProductTypes) }
    }

    // MARK: - Здоровье батареи (фаза 6)

    /// Даты как секунды с эпохи: словарь уходит в plist, и ISO-строки там ни к чему.
    private static let healthCoders: (JSONEncoder, JSONDecoder) = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (encoder, decoder)
    }()

    /// UDID → JSON-строка со здоровьем.
    static var batteryHealth: [String: String] {
        get { stringMap(Key.batteryHealth) }
        set { setStringMap(newValue, Key.batteryHealth) }
    }

    static func health(udid: String) -> BatteryHealth? {
        guard let json = batteryHealth[udid], let data = json.data(using: .utf8) else { return nil }
        return try? healthCoders.1.decode(BatteryHealth.self, from: data)
    }

    /// nil стирает запись: пустой словарь убирает ключ целиком, как у адресов.
    static func setHealth(_ value: BatteryHealth?, udid: String) {
        guard let value else {
            batteryHealth[udid] = nil
            return
        }
        guard let data = try? healthCoders.0.encode(value),
              let json = String(data: data, encoding: .utf8) else { return }
        batteryHealth[udid] = json
    }

    /// UDID → когда последний раз стучались за здоровьем (успешно или нет).
    static var healthAttemptedAt: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: Key.healthAttemptedAt) as? [String: Double] ?? [:] }
        set {
            if newValue.isEmpty {
                UserDefaults.standard.removeObject(forKey: Key.healthAttemptedAt)
            } else {
                UserDefaults.standard.set(newValue, forKey: Key.healthAttemptedAt)
            }
        }
    }

    static func healthAttempt(udid: String) -> Date? {
        healthAttemptedAt[udid].map { Date(timeIntervalSince1970: $0) }
    }

    static func setHealthAttempt(_ date: Date, udid: String) {
        healthAttemptedAt[udid] = date.timeIntervalSince1970
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
/// `AKB_FAKE_PERCENT`, `AKB_FAKE_CHARGING`, `AKB_FAKE_STALE_AFTER`,
/// `AKB_FAKE_TOGGLE_CHARGING`.
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

    /// Каждые N секунд фейковый телефон встаёт на зарядку и снимается с неё
    /// (`AKB_FAKE_TOGGLE_CHARGING`) — так проверяется, что молния в строке меню
    /// меняется сама, без открытия popover (план §20.3).
    static var toggleCharging: TimeInterval? {
        guard let raw = ProcessInfo.processInfo.environment["AKB_FAKE_TOGGLE_CHARGING"],
              let value = TimeInterval(raw), value > 0 else { return nil }
        return value
    }

    /// Первые N секунд фейковый телефон заряжается, потом стоит на проводе без
    /// зарядки с `NotChargingReason` лимита (`AKB_FAKE_CHARGE_DONE`, план §7.8) —
    /// так проверяется уведомление «отключи от зарядки» без рук пользователя.
    static var chargeDone: TimeInterval? {
        guard let raw = ProcessInfo.processInfo.environment["AKB_FAKE_CHARGE_DONE"],
              let value = TimeInterval(raw), value >= 0 else { return nil }
        return value
    }

    /// Принудительно «здоровье не читается» — для снимка раздела без данных (план §6.5).
    static var forceNoHealth: Bool {
        IMobileDeviceOutputParser.bool(ProcessInfo.processInfo.environment["AKB_FAKE_NO_HEALTH"])
    }

    /// Принудительно «телефон не найден».
    static var forceNoDevice: Bool {
        IMobileDeviceOutputParser.bool(ProcessInfo.processInfo.environment["AKB_FAKE_NO_DEVICE"])
    }

    static var isActive: Bool { percent != nil }
}

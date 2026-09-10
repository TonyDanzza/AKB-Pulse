import Foundation
import Testing
@testable import AKB

/// Настоящий вывод `akb-direct health` с телефона Тони (iPhone 17, iOS 26).
private let realOutput = """
CycleCount: 243
Voltage: 4197
InstantAmperage: -23
Amperage: -58
TimeRemaining: 1472
IsCharging: false
ExternalConnected: false
DesignCapacity: 3654
NominalChargeCapacity: 3609
FullChargeCapacity: 3632
"""

@Suite("Разбор здоровья батареи")
struct BatteryHealthParserTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Живой вывод помощника разбирается целиком")
    func realAnswer() throws {
        let health = try #require(IMobileDeviceOutputParser.health(realOutput, now: now))
        #expect(health.cycleCount == 243)
        #expect(health.designCapacity == 3654)
        #expect(health.nominalCapacity == 3609)
        #expect(health.fullChargeCapacity == 3632)
        #expect(health.voltage == 4197)
        #expect(health.amperage == -23)      // мгновенный ток честнее усреднённого
        #expect(health.temperature == nil)   // прошивка её не отдаёт
        #expect(health.timeRemaining == 1472)
        #expect(health.updatedAt == now)
        #expect(health.maximumCapacityPercent == 99)
    }

    @Test("Мусор и пустые строки не мешают")
    func noise() throws {
        let text = "\n  \nвсякое без двоеточия\n" + realOutput + "\n\n"
        #expect(IMobileDeviceOutputParser.health(text)?.cycleCount == 243)
    }

    @Test("Без CycleCount — nil")
    func missingCycles() {
        let text = realOutput.split(separator: "\n")
            .filter { !$0.hasPrefix("CycleCount") }.joined(separator: "\n")
        #expect(IMobileDeviceOutputParser.health(text) == nil)
    }

    @Test("Проектная ёмкость 0 — nil: делить не на что")
    func zeroDesign() {
        let text = realOutput.replacingOccurrences(of: "DesignCapacity: 3654",
                                                   with: "DesignCapacity: 0")
        #expect(IMobileDeviceOutputParser.health(text) == nil)
    }

    @Test("Без полной ёмкости — nil")
    func missingNominal() {
        let text = realOutput.split(separator: "\n")
            .filter { !$0.hasPrefix("NominalChargeCapacity") }.joined(separator: "\n")
        #expect(IMobileDeviceOutputParser.health(text) == nil)
    }

    @Test("Без InstantAmperage ток берётся из Amperage")
    func fallbackToAverage() throws {
        let text = realOutput.split(separator: "\n")
            .filter { !$0.hasPrefix("InstantAmperage") }.joined(separator: "\n")
        let health = try #require(IMobileDeviceOutputParser.health(text))
        #expect(health.amperage == -58)
    }

    @Test("Тока нет вовсе — поле пустое, остальное читается")
    func noAmperage() throws {
        let text = realOutput.split(separator: "\n")
            .filter { !$0.hasPrefix("InstantAmperage") && !$0.hasPrefix("Amperage") }
            .joined(separator: "\n")
        let health = try #require(IMobileDeviceOutputParser.health(text))
        #expect(health.amperage == nil)
    }

    @Test("Температура приходит в сотых долях градуса: 2850 → 28,5")
    func temperature() throws {
        let health = try #require(IMobileDeviceOutputParser.health(realOutput + "\nTemperature: 2850"))
        #expect(health.temperature == 28.5)
    }

    @Test("TimeRemaining 65535 и ноль значат «не знаю»")
    func unknownTimeRemaining() throws {
        for raw in ["65535", "0", "-1"] {
            let text = realOutput.replacingOccurrences(of: "TimeRemaining: 1472",
                                                       with: "TimeRemaining: \(raw)")
            #expect(try #require(IMobileDeviceOutputParser.health(text)).timeRemaining == nil)
        }
        let text = realOutput.split(separator: "\n")
            .filter { !$0.hasPrefix("TimeRemaining") }.joined(separator: "\n")
        #expect(IMobileDeviceOutputParser.health(text)?.timeRemaining == nil)
    }

    @Test("Отрицательные числа не превращаются в огромные положительные")
    func negativeStaysNegative() throws {
        let text = realOutput.replacingOccurrences(of: "InstantAmperage: -23",
                                                   with: "InstantAmperage: -1200")
        #expect(try #require(IMobileDeviceOutputParser.health(text)).amperage == -1200)
    }
}

@Suite("Максимальная ёмкость в процентах")
struct MaximumCapacityTests {

    private func percent(nominal: Int, design: Int = 3654) -> Int {
        BatteryHealth(cycleCount: 0, designCapacity: design, nominalCapacity: nominal)
            .maximumCapacityPercent
    }

    @Test("Новая батарея — 100 %")
    func brandNew() { #expect(percent(nominal: 3654) == 100) }

    @Test("Больше проектной — всё равно 100 %, а не 101")
    func aboveDesign() { #expect(percent(nominal: 3700) == 100) }

    @Test("3609 из 3654 — 99 %, округление вверх, а не усечение до 98")
    func rounding() { #expect(percent(nominal: 3609) == 99) }

    @Test("Почти пустая батарея — 0 %")
    func almostNothing() { #expect(percent(nominal: 1) == 0) }

    @Test("Проектная ёмкость 0 — 0 %, деления на ноль нет")
    func zeroDesign() { #expect(percent(nominal: 3609, design: 0) == 0) }
}

@MainActor
@Suite("Когда пора спрашивать здоровье")
struct HealthIsDueTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func health(ageMinutes: Double) -> BatteryHealth {
        BatteryHealth(cycleCount: 243, designCapacity: 3654, nominalCapacity: 3609,
                      updatedAt: now.addingTimeInterval(-ageMinutes * 60))
    }

    private func due(_ value: BatteryHealth?, attemptMinutesAgo: Double?) -> Bool {
        BatteryMonitor.healthIsDue(health: value,
                                   lastAttempt: attemptMinutesAgo.map { now.addingTimeInterval(-$0 * 60) },
                                   now: now)
    }

    @Test("Здоровья нет и попыток не было — пора")
    func neverRead() { #expect(due(nil, attemptMinutesAgo: nil)) }

    @Test("Свежее здоровье — не пора")
    func fresh() { #expect(due(health(ageMinutes: 5), attemptMinutesAgo: nil) == false) }

    @Test("Старше часа — пора")
    func hourOld() { #expect(due(health(ageMinutes: 61), attemptMinutesAgo: nil)) }

    @Test("Ровно час — уже пора")
    func exactlyHour() { #expect(due(health(ageMinutes: 60), attemptMinutesAgo: nil)) }

    @Test("Старше часа, но пробовали 5 минут назад — не пора")
    func recentAttempt() { #expect(due(health(ageMinutes: 61), attemptMinutesAgo: 5) == false) }

    @Test("Старше часа и пробовали 11 минут назад — пора")
    func oldAttempt() { #expect(due(health(ageMinutes: 61), attemptMinutesAgo: 11)) }

    @Test("Данных нет, но попытка была минуту назад — ждём")
    func noDataRecentAttempt() { #expect(due(nil, attemptMinutesAgo: 1) == false) }
}

@Suite("Память о здоровье батареи", .serialized)
struct HealthPrefsTests {

    private func sample(cycles: Int = 243) -> BatteryHealth {
        BatteryHealth(cycleCount: cycles, designCapacity: 3654, nominalCapacity: 3609,
                      fullChargeCapacity: 3632, voltage: 4197, amperage: -58,
                      temperature: 28.5, timeRemaining: 1472,
                      updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                      source: .direct)
    }

    @Test("Запись и чтение по UDID переживают все поля")
    func roundTrip() throws {
        let udid = "HEALTH-\(UUID().uuidString)"
        defer { Prefs.setHealth(nil, udid: udid) }
        Prefs.setHealth(sample(), udid: udid)
        let restored = try #require(Prefs.health(udid: udid))
        #expect(restored == sample())
        #expect(restored.source == .direct)
    }

    @Test("nil стирает запись, а последняя запись убирает ключ целиком")
    func removal() {
        let saved = Prefs.batteryHealth
        defer { Prefs.batteryHealth = saved }
        Prefs.batteryHealth = [:]
        let udid = "HEALTH-\(UUID().uuidString)"
        Prefs.setHealth(sample(), udid: udid)
        #expect(UserDefaults.standard.object(forKey: Prefs.Key.batteryHealth) != nil)
        Prefs.setHealth(nil, udid: udid)
        #expect(Prefs.health(udid: udid) == nil)
        #expect(UserDefaults.standard.object(forKey: Prefs.Key.batteryHealth) == nil)
    }

    @Test("Два телефона не мешают друг другу")
    func twoDevices() {
        let first = "HEALTH-\(UUID().uuidString)"
        let second = "HEALTH-\(UUID().uuidString)"
        defer {
            Prefs.setHealth(nil, udid: first)
            Prefs.setHealth(nil, udid: second)
        }
        Prefs.setHealth(sample(cycles: 243), udid: first)
        Prefs.setHealth(sample(cycles: 12), udid: second)
        #expect(Prefs.health(udid: first)?.cycleCount == 243)
        #expect(Prefs.health(udid: second)?.cycleCount == 12)
        Prefs.setHealth(nil, udid: first)
        #expect(Prefs.health(udid: first) == nil)
        #expect(Prefs.health(udid: second)?.cycleCount == 12)
    }

    @Test("Неизвестный UDID и битый JSON — nil, а не падение")
    func brokenValue() {
        let udid = "HEALTH-\(UUID().uuidString)"
        defer { Prefs.setHealth(nil, udid: udid) }
        #expect(Prefs.health(udid: udid) == nil)
        Prefs.batteryHealth[udid] = "не json"
        #expect(Prefs.health(udid: udid) == nil)
    }

    @Test("Дата попытки переживает запись и чтение")
    func attemptRoundTrip() {
        let udid = "HEALTH-\(UUID().uuidString)"
        defer { Prefs.healthAttemptedAt[udid] = nil }
        #expect(Prefs.healthAttempt(udid: udid) == nil)
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        Prefs.setHealthAttempt(date, udid: udid)
        #expect(Prefs.healthAttempt(udid: udid) == date)
    }
}

@Suite("Числа здоровья в тексте")
struct HealthFormatterTests {

    private let ru = Locale(identifier: "ru_RU")
    private let en = Locale(identifier: "en_US")

    @Test("Напряжение: два знака после запятой и единица по локали")
    func voltage() {
        #expect(HealthFormatter.voltage(4197, locale: ru) == "4,20 В")
        #expect(HealthFormatter.voltage(4197, locale: en) == "4.20 V")
    }

    @Test("Ток: настоящий минус, а не дефис")
    func amperage() {
        #expect(HealthFormatter.amperage(-58, locale: ru) == "\u{2212}58 мА")
        #expect(HealthFormatter.amperage(-58, locale: ru).contains("-") == false)
        #expect(HealthFormatter.amperage(120, locale: ru) == "120 мА")
    }

    @Test("Температура: одна цифра после запятой, градус не отрывается от числа")
    func temperature() {
        // Между числом и «°C» система ставит неразрывный пробел — так и надо.
        #expect(HealthFormatter.temperature(28.5, locale: ru) == "28,5\u{00A0}°C")
    }

    @Test("Ёмкость: «3609 из 3654 мА·ч», без разделителя тысяч")
    func capacity() {
        let health = BatteryHealth(cycleCount: 243, designCapacity: 3654, nominalCapacity: 3609)
        #expect(HealthFormatter.capacityLine(health, locale: ru) == "3609 из 3654 мА·ч")
    }

    @Test("Проценты с неразрывным пробелом")
    func percent() {
        #expect(HealthFormatter.percent(99, locale: ru) == "99\u{00A0}%")
    }
}

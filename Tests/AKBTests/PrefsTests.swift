import Foundation
import Testing

@Suite("Память о телефоне в UserDefaults", .serialized)
struct PrefsTests {

    private func cleanup(_ udid: String) {
        Prefs.deviceNames[udid] = nil
        Prefs.deviceProductTypes[udid] = nil
        Prefs.lastKnownIP[udid] = nil
        Prefs.ipConfirmedAt[udid] = nil
    }

    @Test("remember + cachedDevice")
    func rememberAndRestore() {
        let udid = "PREFS-\(UUID().uuidString)"
        defer { cleanup(udid) }
        Prefs.remember(PhoneDevice(udid: udid, name: "iPhone (Тони)", productType: "iPhone18,3", transport: .usb))
        let cached = Prefs.cachedDevice(udid: udid)
        #expect(cached?.name == "iPhone (Тони)")
        #expect(cached?.productType == "iPhone18,3")
        // Из кэша телефон всегда «по Wi-Fi»: до спящего можно достучаться только так.
        #expect(cached?.transport == .wifi)
    }

    @Test("Пустая модель не затирает известную")
    func emptyProductTypeKeepsOld() {
        let udid = "PREFS-\(UUID().uuidString)"
        defer { cleanup(udid) }
        Prefs.remember(PhoneDevice(udid: udid, name: "a", productType: "iPhone18,3", transport: .wifi))
        Prefs.remember(PhoneDevice(udid: udid, name: "b", productType: "", transport: .wifi))
        #expect(Prefs.cachedDevice(udid: udid)?.name == "b")
        #expect(Prefs.cachedDevice(udid: udid)?.productType == "iPhone18,3")
    }

    @Test("Неизвестный UDID — nil")
    func unknownDevice() {
        #expect(Prefs.cachedDevice(udid: "PREFS-NOBODY-\(UUID().uuidString)") == nil)
    }

    @Test("Опустевший словарь удаляет ключ из UserDefaults")
    func emptyMapRemovesKey() {
        let saved = Prefs.lastKnownIP
        defer { Prefs.lastKnownIP = saved }
        Prefs.lastKnownIP = [:]
        #expect(UserDefaults.standard.object(forKey: Prefs.Key.lastKnownIP) == nil)
        Prefs.lastKnownIP["u"] = "192.168.1.11"
        #expect(UserDefaults.standard.object(forKey: Prefs.Key.lastKnownIP) != nil)
        Prefs.lastKnownIP["u"] = nil
        #expect(UserDefaults.standard.object(forKey: Prefs.Key.lastKnownIP) == nil)
    }

    @Test("Дата подтверждения адреса переживает запись и чтение")
    func confirmedAtRoundTrip() {
        let udid = "PREFS-\(UUID().uuidString)"
        defer { cleanup(udid) }
        let cache = PrefsAddressCache()
        let date = Date(timeIntervalSince1970: 1_700_000_000.5)
        cache.setConfirmedAt(date, for: udid)
        #expect(cache.confirmedAt(for: udid) == date)
        cache.setConfirmedAt(nil, for: udid)
        #expect(cache.confirmedAt(for: udid) == nil)
    }

    @Test("Кэш адреса через Prefs: IP, MAC, имя")
    func prefsAddressCache() {
        let udid = "PREFS-\(UUID().uuidString)"
        defer {
            cleanup(udid)
            Prefs.lastKnownMAC[udid] = nil
            Prefs.lastKnownHostname[udid] = nil
        }
        let cache = PrefsAddressCache()
        cache.setIP("192.168.1.11", for: udid)
        cache.setMAC("34:10:be:d8:21:09", for: udid)
        cache.setHostname("iPhone-Toni.local.", for: udid)
        #expect(cache.ip(for: udid) == "192.168.1.11")
        #expect(cache.mac(for: udid) == "34:10:be:d8:21:09")
        #expect(cache.hostname(for: udid) == "iPhone-Toni.local.")
        cache.setIP(nil, for: udid)
        #expect(cache.ip(for: udid) == nil)
        #expect(cache.mac(for: udid) == "34:10:be:d8:21:09")
    }

    @Test("Запомненных телефонов несколько — берётся семейство iPhone 17, не первый по UDID")
    func cachedDevicePicksIPhone17Family() {
        let savedNames = Prefs.deviceNames
        let savedTypes = Prefs.deviceProductTypes
        let savedUDID = Prefs.selectedUDID
        defer {
            Prefs.deviceNames = savedNames
            Prefs.deviceProductTypes = savedTypes
            Prefs.selectedUDID = savedUDID
        }
        Prefs.deviceNames = [:]
        Prefs.deviceProductTypes = [:]
        Prefs.selectedUDID = nil
        Prefs.remember(PhoneDevice(udid: "A-OLD", name: "Старый", productType: "iPhone15,4", transport: .usb))
        Prefs.remember(PhoneDevice(udid: "B-NEW", name: "Новый", productType: "iPhone18,3", transport: .wifi))
        // Без выбранного телефона побеждает не «A» по алфавиту, а iPhone 17 (план §6).
        #expect(IMobileDeviceProvider().cachedDevice()?.productType == "iPhone18,3")
        Prefs.selectedUDID = "A-OLD"
        #expect(IMobileDeviceProvider().cachedDevice()?.udid == "A-OLD")
    }

    @Test("Новые ключи уведомлений по умолчанию включены")
    func notificationDefaults() {
        Prefs.registerDefaults()
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        #expect(registered[Prefs.Key.notificationsEnabled] as? Bool == true)
        #expect(registered[Prefs.Key.notifyLowBattery] as? Bool == true)
        #expect(registered[Prefs.Key.notifyChargeDone] as? Bool == true)
        // Ключи — часть формата настроек пользователя, менять их нельзя.
        #expect(Prefs.Key.notificationsEnabled == "notificationsEnabled")
        #expect(Prefs.Key.notifyChargeDone == "notifyChargeDone")
    }

    @Test("Общий выключатель и отдельные читаются из UserDefaults")
    func notificationSwitches() {
        let defaults = UserDefaults.standard
        let savedAll = defaults.object(forKey: Prefs.Key.notificationsEnabled)
        let savedDone = defaults.object(forKey: Prefs.Key.notifyChargeDone)
        defer {
            defaults.set(savedAll, forKey: Prefs.Key.notificationsEnabled)
            defaults.set(savedDone, forKey: Prefs.Key.notifyChargeDone)
        }
        defaults.set(false, forKey: Prefs.Key.notificationsEnabled)
        defaults.set(true, forKey: Prefs.Key.notifyChargeDone)
        #expect(Prefs.notificationsEnabled == false)
        #expect(Prefs.notifyChargeDone == true)
        defaults.set(true, forKey: Prefs.Key.notificationsEnabled)
        defaults.set(false, forKey: Prefs.Key.notifyChargeDone)
        #expect(Prefs.notificationsEnabled == true)
        #expect(Prefs.notifyChargeDone == false)
    }

    @Test("Допустимые интервалы опроса")
    func pollIntervals() {
        #expect(Prefs.pollIntervals == [30, 60, 120, 300])
        #expect(Prefs.pollIntervals == Prefs.pollIntervals.sorted())
    }
}

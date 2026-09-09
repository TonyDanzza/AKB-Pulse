import Foundation
import Testing

@Suite("Парсер вывода libimobiledevice")
struct IMobileDeviceOutputParserTests {

    /// Реальный вывод `ideviceinfo -n -u <udid> -q com.apple.mobile.battery`.
    static let batterySample = """
    BatteryCurrentCapacity: 72
    BatteryIsCharging: false
    ExternalChargeCapable: false
    ExternalConnected: false
    FullyCharged: false
    GasGaugeCapability: true
    HasBattery: true
    """

    @Test("Нормальный вывод разбирается целиком")
    func normalBattery() throws {
        let status = try #require(IMobileDeviceOutputParser.battery(Self.batterySample))
        #expect(status.percent == 72)
        #expect(status.isCharging == false)
        #expect(status.externalConnected == false)
        #expect(status.fullyCharged == false)
    }

    @Test("Зарядка и подключённое питание")
    func chargingBattery() throws {
        let text = """
        BatteryCurrentCapacity: 100
        BatteryIsCharging: true
        ExternalConnected: true
        FullyCharged: true
        """
        let status = try #require(IMobileDeviceOutputParser.battery(text))
        #expect(status.percent == 100)
        #expect(status.isCharging)
        #expect(status.externalConnected)
        #expect(status.fullyCharged)
        #expect(status.level == .high)
    }

    @Test("Пустой вывод и мусор дают nil")
    func emptyAndGarbage() {
        #expect(IMobileDeviceOutputParser.battery("") == nil)
        #expect(IMobileDeviceOutputParser.battery("\n\n   \n") == nil)
        #expect(IMobileDeviceOutputParser.battery("ERROR: No device found.") == nil)
        #expect(IMobileDeviceOutputParser.battery("BatteryCurrentCapacity: полно") == nil)
    }

    @Test("Отсутствие ключа ёмкости даёт nil")
    func missingCapacity() {
        let text = """
        BatteryIsCharging: false
        FullyCharged: false
        """
        #expect(IMobileDeviceOutputParser.battery(text) == nil)
    }

    @Test("Проценты зажимаются в 0…100")
    func clamping() throws {
        let high = try #require(IMobileDeviceOutputParser.battery("BatteryCurrentCapacity: 240"))
        #expect(high.percent == 100)
        let low = try #require(IMobileDeviceOutputParser.battery("BatteryCurrentCapacity: -5"))
        #expect(low.percent == 0)
    }

    @Test("Булевы значения понимают true/1/YES")
    func booleans() {
        #expect(IMobileDeviceOutputParser.bool("true"))
        #expect(IMobileDeviceOutputParser.bool("TRUE"))
        #expect(IMobileDeviceOutputParser.bool("1"))
        #expect(IMobileDeviceOutputParser.bool(" Yes "))
        #expect(!IMobileDeviceOutputParser.bool("false"))
        #expect(!IMobileDeviceOutputParser.bool("0"))
        #expect(!IMobileDeviceOutputParser.bool(nil))
        #expect(!IMobileDeviceOutputParser.bool("что угодно"))
    }

    @Test("Пары ключ-значение: двоеточие в значении не ломает разбор")
    func keyValues() {
        let kv = IMobileDeviceOutputParser.keyValues("""
        DeviceName: iPhone (Тони): рабочий
        мусор без двоеточия
        : пустой ключ

        ProductType: iPhone18,3
        """)
        #expect(kv["DeviceName"] == "iPhone (Тони): рабочий")
        #expect(kv["ProductType"] == "iPhone18,3")
        #expect(kv.count == 2)
    }

    @Test("Список UDID отбрасывает сообщения и дубли")
    func udidList() {
        let text = """
        00008150-000A1B2C3D4E5F60
        00008150-000A1B2C3D4E5F60
        4d7f2a1b9c8e5f3a6b0d2c4e8f1a3b5c7d9e0f21
        No device found.
        """
        #expect(IMobileDeviceOutputParser.udidList(text) == [
            "00008150-000A1B2C3D4E5F60",
            "4d7f2a1b9c8e5f3a6b0d2c4e8f1a3b5c7d9e0f21"
        ])
        #expect(IMobileDeviceOutputParser.udidList("").isEmpty)
        #expect(IMobileDeviceOutputParser.udidList("ERROR: Unable to retrieve device list!").isEmpty)
    }

    @Test("Одиночное значение берёт первую непустую строку")
    func singleValue() {
        #expect(IMobileDeviceOutputParser.singleValue("  iPhone (Тони)\n") == "iPhone (Тони)")
        #expect(IMobileDeviceOutputParser.singleValue("iPhone18,3\nхвост") == "iPhone18,3")
        #expect(IMobileDeviceOutputParser.singleValue("   \n  ") == nil)
    }
}

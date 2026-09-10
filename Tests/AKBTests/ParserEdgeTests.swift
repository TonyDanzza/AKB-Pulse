import Foundation
import Testing
@testable import AKB

@Suite("Парсер вывода: края")
struct ParserEdgeTests {

    @Test("Без пробела после двоеточия и с табуляцией")
    func spacingVariants() throws {
        let status = try #require(IMobileDeviceOutputParser.battery("BatteryCurrentCapacity:72\nBatteryIsCharging:\ttrue"))
        #expect(status.percent == 72)
        #expect(status.isCharging)
    }

    @Test("Знак плюс и ведущие нули в числе")
    func numericForms() throws {
        #expect(try #require(IMobileDeviceOutputParser.battery("BatteryCurrentCapacity: +5")).percent == 5)
        #expect(try #require(IMobileDeviceOutputParser.battery("BatteryCurrentCapacity: 007")).percent == 7)
        #expect(IMobileDeviceOutputParser.battery("BatteryCurrentCapacity: 72.0") == nil)
        #expect(IMobileDeviceOutputParser.battery("BatteryCurrentCapacity: 72%") == nil)
    }

    @Test("Повторяющийся ключ — берётся последнее значение")
    func duplicateKey() {
        let kv = IMobileDeviceOutputParser.keyValues("A: 1\nA: 2")
        #expect(kv["A"] == "2")
    }

    @Test("Значение может быть пустым")
    func emptyValue() {
        let kv = IMobileDeviceOutputParser.keyValues("DeviceName:\nProductType: iPhone18,3")
        #expect(kv["DeviceName"] == "")
        #expect(kv["ProductType"] == "iPhone18,3")
    }

    @Test("Время снимка берётся из параметра now")
    func usesInjectedNow() throws {
        let now = Date(timeIntervalSince1970: 123)
        let status = try #require(IMobileDeviceOutputParser.battery("BatteryCurrentCapacity: 1", now: now))
        #expect(status.updatedAt == now)
    }

    @Test("Список UDID: короткие, с пробелами, с посторонними символами — отбрасываются")
    func udidFiltering() {
        let text = """
        abcdef1
        00008150-000A1B2C3D4E5F60 extra
        00008150_000A1B2C3D4E5F60
        \t4d7f2a1b9c8e5f3a6b0d2c4e8f1a3b5c7d9e0f21\t
        """
        #expect(IMobileDeviceOutputParser.udidList(text) == ["4d7f2a1b9c8e5f3a6b0d2c4e8f1a3b5c7d9e0f21"])
    }

    @Test("UDID в разном регистре считаются разными строками")
    func udidCaseSensitive() {
        let text = "00008150-000A1B2C3D4E5F60\n00008150-00086dc21492401c"
        #expect(IMobileDeviceOutputParser.udidList(text).count == 2)
    }

    @Test("Одиночное значение с пустыми строками перед ним")
    func singleValueLeadingBlank() {
        #expect(IMobileDeviceOutputParser.singleValue("\n\n  iPhone (Тони)  \n") == "iPhone (Тони)")
    }
}

import Foundation
import Testing

@Suite("Соответствие ProductType и модели")
struct ProductTypeMapTests {

    @Test("iPhone 17 семейства iPhone18,*")
    func iPhone17Family() {
        #expect(ProductTypeMap.displayName(for: "iPhone18,3") == "iPhone 17")
        #expect(ProductTypeMap.displayName(for: "iPhone18,1") == "iPhone 17 Pro")
        #expect(ProductTypeMap.displayName(for: "iPhone18,2") == "iPhone 17 Pro Max")
        #expect(ProductTypeMap.displayName(for: "iPhone18,4") == "iPhone Air")
    }

    @Test("Известные предыдущие поколения")
    func olderGenerations() {
        #expect(ProductTypeMap.displayName(for: "iPhone17,3") == "iPhone 16")
        #expect(ProductTypeMap.displayName(for: "iPhone16,1") == "iPhone 15 Pro")
        #expect(ProductTypeMap.displayName(for: "iPhone15,4") == "iPhone 15")
    }

    @Test("Неизвестный ProductType показывается как есть")
    func unknownPassThrough() {
        #expect(ProductTypeMap.displayName(for: "iPhone99,9") == "iPhone99,9")
        #expect(ProductTypeMap.isKnown("iPhone99,9") == false)
        #expect(ProductTypeMap.isKnown("iPhone18,3"))
    }

    @Test("Пустая строка и пробелы")
    func emptyInput() {
        #expect(ProductTypeMap.displayName(for: "") == "iPhone")
        #expect(ProductTypeMap.displayName(for: "   ") == "iPhone")
        #expect(ProductTypeMap.displayName(for: " iPhone18,3 ") == "iPhone 17")
    }

    @Test("PhoneDevice отдаёт модель и заголовок для Picker")
    func phoneDevice() {
        let device = PhoneDevice(udid: "00008150-000A1B2C3D4E5F60",
                                 name: "iPhone (Тони)",
                                 productType: "iPhone18,3",
                                 transport: .wifi)
        #expect(device.modelName == "iPhone 17")
        #expect(device.isIPhone17Family)
        #expect(device.pickerTitle == "iPhone (Тони) — iPhone 17 (Wi-Fi)")
        #expect(device.id == device.udid)

        let older = PhoneDevice(udid: "x", name: "n", productType: "iPhone17,3", transport: .usb)
        #expect(older.isIPhone17Family == false)
        #expect(older.transport.displayName == "USB")
    }

    @Test("Выбор устройства: сохранённый UDID → iPhone 17 → первый") @MainActor
    func devicePicking() {
        let a = PhoneDevice(udid: "A", name: "Старый", productType: "iPhone15,4", transport: .usb)
        let b = PhoneDevice(udid: "B", name: "Новый", productType: "iPhone18,3", transport: .wifi)
        #expect(BatteryMonitor.pick(from: [a, b], preferredUDID: "A")?.udid == "A")
        #expect(BatteryMonitor.pick(from: [a, b], preferredUDID: nil)?.udid == "B")
        #expect(BatteryMonitor.pick(from: [a, b], preferredUDID: "нет такого")?.udid == "B")
        #expect(BatteryMonitor.pick(from: [a], preferredUDID: nil)?.udid == "A")
        #expect(BatteryMonitor.pick(from: [], preferredUDID: nil) == nil)
    }
}

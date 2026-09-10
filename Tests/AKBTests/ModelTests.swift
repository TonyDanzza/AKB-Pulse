import Foundation
import Testing

@Suite("Снимок батареи")
struct BatteryStatusTests {

    @Test("Границы уровней: 9/10, 19/20, 39/40")
    func levelBoundaries() {
        #expect(BatteryStatus(percent: 0).level == .critical)
        #expect(BatteryStatus(percent: 9).level == .critical)
        #expect(BatteryStatus(percent: 10).level == .low)
        #expect(BatteryStatus(percent: 19).level == .low)
        #expect(BatteryStatus(percent: 20).level == .medium)
        #expect(BatteryStatus(percent: 39).level == .medium)
        #expect(BatteryStatus(percent: 40).level == .high)
        #expect(BatteryStatus(percent: 100).level == .high)
    }

    @Test("Проценты зажимаются в 0…100 уже в инициализаторе")
    func clamping() {
        #expect(BatteryStatus(percent: -1).percent == 0)
        #expect(BatteryStatus(percent: 101).percent == 100)
        #expect(BatteryStatus(percent: Int.max).percent == 100)
        #expect(BatteryStatus(percent: Int.min).percent == 0)
    }

    @Test("Доля заряда и признак бодрствования")
    func fractionAndAwake() {
        #expect(BatteryStatus(percent: 50).fraction == 0.5)
        #expect(BatteryStatus(percent: 0).fraction == 0)
        #expect(BatteryStatus(percent: 100).fraction == 1)
        #expect(BatteryStatus(percent: 50, source: .usbmuxd).isAwake)
        #expect(BatteryStatus(percent: 50, source: .direct).isAwake == false)
    }

    @Test("Строка флагов для лога")
    func flags() {
        let charging = BatteryStatus(percent: 50, isCharging: true, externalConnected: true)
        #expect(IMobileDeviceProvider.flags(charging) == "зарядка: да, питание: да,")
        let idle = BatteryStatus(percent: 50)
        #expect(IMobileDeviceProvider.flags(idle) == "зарядка: нет, питание: нет,")
    }
}

@Suite("Устройство")
struct PhoneDeviceTests {

    @Test("Codable туда и обратно")
    func codableRoundTrip() throws {
        let device = PhoneDevice(udid: "00008150-000A1B2C3D4E5F60",
                                 name: "iPhone (Тони)",
                                 productType: "iPhone18,3",
                                 transport: .wifi)
        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(PhoneDevice.self, from: data)
        #expect(decoded == device)
    }

    @Test("Символы и имена транспорта")
    func transport() {
        #expect(PhoneDevice.Transport.wifi.symbolName == "wifi")
        #expect(PhoneDevice.Transport.usb.symbolName == "cable.connector")
        #expect(PhoneDevice.Transport.allCases.count == 2)
    }

    @Test("Пустой ProductType — просто «iPhone»")
    func emptyProductType() {
        let device = PhoneDevice(udid: "x", name: "n", productType: "", transport: .wifi)
        #expect(device.modelName == "iPhone")
        #expect(device.isIPhone17Family == false)
        #expect(device.pickerTitle == "n — iPhone (Wi-Fi)")
    }
}

@Suite("Ошибки источника")
struct ProviderErrorTests {

    @Test("У каждой ошибки есть заголовок и символ")
    func everyCaseHasUI() {
        let all: [ProviderError] = [.toolNotFound, .noDevice, .deviceUnreachable("u"), .parseFailure, .timeout]
        for error in all {
            #expect(error.titleKey.hasPrefix("error."))
            #expect(error.titleKey.hasSuffix(".title"))
            #expect(!error.symbolName.isEmpty)
        }
    }
}

@Suite("Подставной источник (AKB_FAKE_*)")
struct FakeProviderTests {

    private let device = PhoneDevice(udid: "FAKE-0000-0000", name: "f", productType: "iPhone18,3", transport: .wifi)

    @Test("Без засыпания отвечает всегда")
    func alwaysAnswers() async throws {
        let provider = FakeProvider(percent: 42, isCharging: true, staleAfter: nil, toggleCharging: nil)
        let devices = try await provider.listDevices()
        #expect(devices.count == 1)
        let status = try await provider.battery(for: device)
        #expect(status.percent == 42)
        #expect(status.isCharging)
        #expect(status.externalConnected)
        #expect(status.fullyCharged == false)
        #expect(status.source == .usbmuxd)
    }

    @Test("staleAfter = 0 — телефон «уснул» сразу")
    func asleepImmediately() async {
        let provider = FakeProvider(percent: 42, isCharging: false, staleAfter: 0, toggleCharging: nil)
        await #expect(throws: ProviderError.deviceUnreachable("FAKE-0000-0000")) {
            _ = try await provider.listDevices()
        }
        await #expect(throws: ProviderError.deviceUnreachable("FAKE-0000-0000")) {
            _ = try await provider.battery(for: device)
        }
    }

    @Test("Засыпает только после указанного срока")
    func asleepLater() async throws {
        var provider = FakeProvider(percent: 42, isCharging: false, staleAfter: 100, toggleCharging: nil)
        provider.startedAt = Date()
        _ = try await provider.battery(for: device)
        provider.startedAt = Date().addingTimeInterval(-200)
        await #expect(throws: ProviderError.self) {
            _ = try await provider.battery(for: device)
        }
    }

    @Test("Зарядка мигает с заданным периодом")
    func toggleCharging() async throws {
        var provider = FakeProvider(percent: 42, isCharging: false, staleAfter: nil, toggleCharging: 1000)
        provider.startedAt = Date()
        #expect(try await provider.battery(for: device).isCharging == false)
        provider.startedAt = Date().addingTimeInterval(-1500)   // второй период — перевёрнуто
        #expect(try await provider.battery(for: device).isCharging == true)
        provider.startedAt = Date().addingTimeInterval(-2500)   // третий — снова как было
        #expect(try await provider.battery(for: device).isCharging == false)
    }

    @Test("100% — заряжен полностью")
    func fullyCharged() async throws {
        let provider = FakeProvider(percent: 100, isCharging: false, staleAfter: nil, toggleCharging: nil)
        #expect(try await provider.battery(for: device).fullyCharged)
    }
}

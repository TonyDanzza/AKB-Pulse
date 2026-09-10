import Foundation

/// Источник данных о телефоне и его заряде.
protocol BatteryProvider: Sendable {
    func listDevices() async throws -> [PhoneDevice]
    func battery(for device: PhoneDevice) async throws -> BatteryStatus
    /// Здоровье батареи (план §6.5). Спрашивается раз в час, сразу после
    /// удачного чтения заряда, и его неудача ни на что не влияет.
    func health(for device: PhoneDevice) async throws -> BatteryHealth
}

extension BatteryProvider {
    /// Источник, который про здоровье ничего не знает: так старые стабы в тестах
    /// остаются рабочими и ведут себя как телефон, до которого не достучались.
    func health(for device: PhoneDevice) async throws -> BatteryHealth {
        throw ProviderError.deviceUnreachable(device.udid)
    }
}

import Foundation

/// Источник данных о телефоне и его заряде.
protocol BatteryProvider: Sendable {
    func listDevices() async throws -> [PhoneDevice]
    func battery(for device: PhoneDevice) async throws -> BatteryStatus
}

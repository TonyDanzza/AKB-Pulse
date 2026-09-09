import Foundation

/// Найденный iPhone: идентификатор, имя, модель и способ подключения.
struct PhoneDevice: Sendable, Equatable, Hashable, Identifiable, Codable {

    enum Transport: String, Sendable, Codable, CaseIterable {
        case wifi
        case usb

        /// Имя SF Symbol для индикатора транспорта. Оба символа проверены на macOS 27.
        var symbolName: String {
            switch self {
            case .wifi: "wifi"
            case .usb: "cable.connector"
            }
        }

        var displayName: String {
            switch self {
            case .wifi: "Wi-Fi"
            case .usb: "USB"
            }
        }
    }

    var udid: String
    var name: String
    var productType: String
    var transport: Transport

    var id: String { udid }

    /// Человеческое имя модели, например «iPhone 17 Pro».
    var modelName: String { ProductTypeMap.displayName(for: productType) }

    /// Семейство iPhone 17 — ProductType вида `iPhone18,*`.
    var isIPhone17Family: Bool { productType.hasPrefix("iPhone18,") }

    /// Строка для Picker в настройках: «Имя — Модель (Wi-Fi)».
    var pickerTitle: String { "\(name) — \(modelName) (\(transport.displayName))" }
}

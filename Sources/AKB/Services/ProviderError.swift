import Foundation

/// Ошибки источника данных о заряде.
enum ProviderError: Error, Equatable, Sendable {
    case toolNotFound
    case noDevice
    case deviceUnreachable(String)
    case parseFailure
    case timeout

    /// Короткий заголовок для UI.
    var titleKey: String {
        switch self {
        case .toolNotFound: "error.toolNotFound.title"
        case .noDevice: "error.noDevice.title"
        case .deviceUnreachable: "error.deviceUnreachable.title"
        case .parseFailure: "error.parseFailure.title"
        case .timeout: "error.timeout.title"
        }
    }

    var descriptionKey: String {
        switch self {
        case .toolNotFound: "error.toolNotFound.description"
        case .noDevice: "error.noDevice.description"
        case .deviceUnreachable: "error.deviceUnreachable.description"
        case .parseFailure: "error.parseFailure.description"
        case .timeout: "error.timeout.description"
        }
    }

    var symbolName: String {
        switch self {
        case .toolNotFound: "exclamationmark.triangle"
        case .noDevice: "iphone.gen3.slash"
        case .deviceUnreachable: "iphone.gen3.slash"
        case .parseFailure: "questionmark.circle"
        case .timeout: "clock.badge.exclamationmark"
        }
    }
}

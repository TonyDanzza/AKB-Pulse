import Foundation

/// Снимок состояния батареи телефона в конкретный момент времени.
struct BatteryStatus: Sendable, Equatable, Hashable {

    /// Уровень заряда для окраски индикатора (как в iOS).
    enum Level: Sendable, Equatable {
        case critical   // < 10
        case low        // < 20
        case medium     // < 40
        case high       // >= 40
    }

    /// Каким путём получен ответ. Косвенный признак сна телефона: через usbmuxd
    /// отвечает только бодрствующий iPhone, спящий — лишь прямым чтением по IP (план §21).
    enum Source: String, Sendable, Equatable, Hashable {
        case usbmuxd
        case direct
    }

    var percent: Int
    var isCharging: Bool
    var externalConnected: Bool
    var fullyCharged: Bool
    var updatedAt: Date
    var source: Source

    init(percent: Int,
         isCharging: Bool = false,
         externalConnected: Bool = false,
         fullyCharged: Bool = false,
         updatedAt: Date = Date(),
         source: Source = .usbmuxd) {
        self.percent = min(max(percent, 0), 100)
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.fullyCharged = fullyCharged
        self.updatedAt = updatedAt
        self.source = source
    }

    /// Телефон не спит: он ответил через usbmuxd (план §21).
    var isAwake: Bool { source == .usbmuxd }

    var level: Level {
        switch percent {
        case ..<10: .critical
        case ..<20: .low
        case ..<40: .medium
        default: .high
        }
    }

    var fraction: Double { Double(percent) / 100.0 }
}

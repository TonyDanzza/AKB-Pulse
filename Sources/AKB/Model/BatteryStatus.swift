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

    var percent: Int
    var isCharging: Bool
    var externalConnected: Bool
    var fullyCharged: Bool
    var updatedAt: Date

    init(percent: Int,
         isCharging: Bool = false,
         externalConnected: Bool = false,
         fullyCharged: Bool = false,
         updatedAt: Date = Date()) {
        self.percent = min(max(percent, 0), 100)
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.fullyCharged = fullyCharged
        self.updatedAt = updatedAt
    }

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

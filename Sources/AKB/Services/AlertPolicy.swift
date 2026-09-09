import Foundation

/// Чистая логика «когда слать уведомление о низком заряде» (план §7).
///
/// Пороги-ступени: `T`, `T-10`, `T-20`, … Каждое пересечение ступени сверху вниз
/// даёт ровно одно уведомление. Состояние сбрасывается, когда телефон поставили
/// на зарядку или заряд снова стал `>= T`.
struct AlertPolicy: Sendable, Equatable {

    var threshold: Int
    var repeatEveryTenPercent: Bool

    /// Ступень, для которой уже отправлено уведомление. `nil` — «взведено».
    private(set) var lastFiredStep: Int?

    init(threshold: Int = 30, repeatEveryTenPercent: Bool = true, lastFiredStep: Int? = nil) {
        self.threshold = threshold
        self.repeatEveryTenPercent = repeatEveryTenPercent
        self.lastFiredStep = lastFiredStep
    }

    /// Все ступени в порядке убывания.
    var steps: [Int] {
        guard repeatEveryTenPercent else { return [threshold] }
        var result: [Int] = []
        var value = threshold
        while value > 0 {
            result.append(value)
            value -= 10
        }
        return result
    }

    /// Обрабатывает очередной замер. Возвращает `true`, если надо отправить уведомление.
    mutating func evaluate(_ status: BatteryStatus) -> Bool {
        // Зарядка или возврат выше порога — снимаем взвод.
        if status.isCharging || status.percent >= threshold {
            lastFiredStep = nil
            return false
        }

        // Самая низкая из уже пересечённых ступеней.
        guard let currentStep = steps.filter({ $0 > status.percent }).min() else {
            return false
        }

        if let last = lastFiredStep, currentStep >= last {
            return false
        }

        lastFiredStep = currentStep
        return true
    }

    /// Полный сброс (например, при смене телефона или порога в настройках).
    mutating func reset() { lastFiredStep = nil }
}

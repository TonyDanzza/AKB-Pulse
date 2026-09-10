import Foundation

/// Чистая логика «когда сказать: отключи от зарядки» (план §7.3).
///
/// Телефон дозарядился — это либо 100 %, либо лимит зарядки iOS (у Тони 80 %).
/// Оба случая выглядят одинаково: провод воткнут, а зарядка не идёт. Отличить
/// лимит от «только воткнули, ещё не начал» помогают два признака:
///
/// - зарядка в этом сеансе уже шла (`sawCharging`) — иначе телефон воткнули
///   уже выше лимита, и говорить «отключи» не о чем;
/// - подтверждение по IORegistry: `BatteryHealth.isAtChargeLimit` (бит
///   `NotChargingReason` 0x01000000). Если оно не пришло — телефон не ответил
///   или пауза непонятная, — срабатывает запасной путь по числу замеров.
///
/// Запасной путь работает только с `minimumLimitPercent` и выше: ниже 80 %
/// лимита в iOS не бывает, значит остановка зарядки там — это пауза (нагрев,
/// оптимизированная зарядка), а не «дозарядился». Подтверждённый лимит и 100 %
/// шлются на любом проценте.
///
/// Один сеанс — одно уведомление. Новый сеанс начинается с втыкания провода.
struct ChargeDonePolicy: Sendable, Equatable {

    enum Verdict: Equatable {
        /// Ничего не делать.
        case none
        /// Похоже на лимит: спросить телефон и вернуть ответ в `confirm(limitReached:)`.
        case needsConfirmation
        /// Слать уведомление.
        case fire
    }

    /// Сколько подряд замеров «на проводе, не заряжается» нужно, если подтверждение
    /// по IORegistry недоступно (телефон на проводе отвечает каждые 5 с → 15 с).
    static let fallbackPolls = 3

    /// Ниже какого заряда запасной путь молчит. Лимит зарядки в iOS («Настройки →
    /// Батарея → Лимит зарядки») ставится только в диапазоне 80…100 %, поэтому
    /// остановка зарядки, скажем, на 50 % — это пауза по нагреву, а не лимит.
    static let minimumLimitPercent = 80

    /// В этом сеансе зарядка шла хотя бы раз.
    private(set) var sawCharging = false
    /// Уведомление об этом сеансе уже ушло.
    private(set) var fired = false
    /// Сколько замеров подряд телефон стоит на проводе без зарядки.
    private(set) var stoppedPolls = 0

    init() {}

    /// Обрабатывает очередной замер заряда.
    mutating func evaluate(_ status: BatteryStatus) -> Verdict {
        guard status.externalConnected else {
            // Провод вынули — сеанс закончился, следующее втыкание начинает новый.
            reset()
            return .none
        }

        if status.isCharging {
            sawCharging = true
            stoppedPolls = 0
            return .none
        }

        // Дальше: провод есть, зарядки нет.
        if fired { return .none }

        // Сто процентов подтверждать нечем и незачем: телефон сам говорит «полон».
        if status.fullyCharged || status.percent >= 100 {
            fired = true
            return .fire
        }

        // Зарядка ни разу не шла: телефон воткнули уже выше лимита или прямо сейчас
        // (первые ~20 с после втыкания он тоже отвечает «питание есть, зарядки нет»).
        guard sawCharging else { return .none }

        stoppedPolls += 1
        if stoppedPolls == 1 { return .needsConfirmation }
        if stoppedPolls >= Self.fallbackPolls, status.percent >= Self.minimumLimitPercent {
            fired = true
            return .fire
        }
        return .none
    }

    /// Ответ на `.needsConfirmation`. Возвращает `true`, если надо слать уведомление.
    ///
    /// Отрицательный ответ — не приговор: зарядка могла встать на паузу из-за
    /// нагрева. Тогда молчим и ждём дальше, но если пауза тянется `fallbackPolls`
    /// замеров при заряде `minimumLimitPercent` и выше, уведомление всё равно уйдёт.
    /// Это осознанный компромисс: лучше редкое лишнее «отключи» через 15 с, чем
    /// молчание про дозарядившийся телефон.
    mutating func confirm(limitReached: Bool) -> Bool {
        guard limitReached, !fired else { return false }
        fired = true
        return true
    }

    /// Полный сброс (провод вынули, сменили телефон).
    mutating func reset() {
        sawCharging = false
        fired = false
        stoppedPolls = 0
    }
}

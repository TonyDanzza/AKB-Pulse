import Foundation
import Testing

/// Сценарии сняты с живого телефона Тони 2026-09-10: воткнули при 76 %,
/// через 20 с пошла зарядка, в 15:06 упёрлись в лимит 80 % — и `FullyCharged`
/// при этом так и остался `false` (план §7.0).
@Suite("Политика «отключи от зарядки»")
struct ChargeDonePolicyTests {

    /// Замер: на проводе и заряжается / на проводе и стоит / без провода.
    private func status(_ percent: Int,
                        plugged: Bool = true,
                        charging: Bool = false,
                        full: Bool = false) -> BatteryStatus {
        BatteryStatus(percent: percent,
                      isCharging: charging,
                      externalConnected: plugged,
                      fullyCharged: full)
    }

    @Test("Только воткнули: питание есть, зарядки ещё нет — молчим")
    func justPluggedIn() {
        var policy = ChargeDonePolicy()
        #expect(policy.evaluate(status(76)) == .none)
        #expect(policy.evaluate(status(76)) == .none)
        #expect(policy.evaluate(status(76)) == .none)
        #expect(policy.fired == false)
        #expect(policy.stoppedPolls == 0)
    }

    @Test("Зарядка шла, встала на лимите — подтверждение по IORegistry и одно уведомление")
    func limitConfirmed() {
        var policy = ChargeDonePolicy()
        #expect(policy.evaluate(status(76)) == .none)
        #expect(policy.evaluate(status(76, charging: true)) == .none)
        #expect(policy.evaluate(status(80, charging: true)) == .none)
        #expect(policy.evaluate(status(80)) == .needsConfirmation)
        #expect(policy.confirm(limitReached: true) == true)
        #expect(policy.fired == true)
        // Дальше телефон стоит на проводе ещё долго — второго уведомления нет.
        #expect(policy.evaluate(status(80)) == .none)
        #expect(policy.evaluate(status(80)) == .none)
        #expect(policy.confirm(limitReached: true) == false)
    }

    @Test("Подтверждение отрицательное: ждём, но после трёх замеров всё равно шлём")
    func notConfirmedFallsBack() {
        var policy = ChargeDonePolicy()
        #expect(policy.evaluate(status(80, charging: true)) == .none)
        #expect(policy.evaluate(status(80)) == .needsConfirmation)
        #expect(policy.confirm(limitReached: false) == false)
        #expect(policy.evaluate(status(80)) == .none)     // второй замер
        #expect(policy.evaluate(status(80)) == .fire)     // третий
        #expect(policy.evaluate(status(80)) == .none)
    }

    @Test("Телефон не ответил на подтверждение — запасной путь даёт ровно одно уведомление")
    func fallbackWithoutConfirm() {
        var policy = ChargeDonePolicy()
        #expect(policy.evaluate(status(80, charging: true)) == .none)
        #expect(policy.evaluate(status(80)) == .needsConfirmation)
        #expect(policy.evaluate(status(80)) == .none)
        #expect(policy.evaluate(status(80)) == .fire)
        #expect(policy.evaluate(status(80)) == .none)
        #expect(policy.evaluate(status(80)) == .none)
        #expect(policy.stoppedPolls == ChargeDonePolicy.fallbackPolls)
    }

    @Test("Сто процентов: FullyCharged даёт уведомление сразу, без подтверждения")
    func fullyChargedFiresAtOnce() {
        var policy = ChargeDonePolicy()
        #expect(policy.evaluate(status(99, charging: true)) == .none)
        #expect(policy.evaluate(status(100, full: true)) == .fire)
        #expect(policy.evaluate(status(100, full: true)) == .none)
    }

    @Test("Воткнули уже полный телефон — уведомление всё равно приходит")
    func pluggedInAlreadyFull() {
        var policy = ChargeDonePolicy()
        #expect(policy.evaluate(status(100, full: true)) == .fire)
        #expect(policy.fired == true)
    }

    @Test("Сто процентов без флага FullyCharged — считаем по проценту")
    func hundredWithoutFlag() {
        var policy = ChargeDonePolicy()
        #expect(policy.evaluate(status(100)) == .fire)
    }

    @Test("Провод вынули — сеанс закрыт, следующий срабатывает заново")
    func unplugResets() {
        var policy = ChargeDonePolicy()
        #expect(policy.evaluate(status(80, charging: true)) == .none)
        #expect(policy.evaluate(status(80)) == .needsConfirmation)
        #expect(policy.confirm(limitReached: true) == true)

        #expect(policy.evaluate(status(79, plugged: false)) == .none)
        #expect(policy.fired == false)
        #expect(policy.sawCharging == false)

        #expect(policy.evaluate(status(60, charging: true)) == .none)
        #expect(policy.evaluate(status(80)) == .needsConfirmation)
        #expect(policy.confirm(limitReached: true) == true)
    }

    @Test("Зарядка встала на один замер и пошла дальше — счётчик обнуляется, уведомления нет")
    func pauseDoesNotFire() {
        var policy = ChargeDonePolicy()
        #expect(policy.evaluate(status(70, charging: true)) == .none)
        #expect(policy.evaluate(status(70)) == .needsConfirmation)
        #expect(policy.confirm(limitReached: false) == false)
        #expect(policy.evaluate(status(71, charging: true)) == .none)
        #expect(policy.stoppedPolls == 0)
        #expect(policy.evaluate(status(72, charging: true)) == .none)
        #expect(policy.fired == false)
    }

    @Test("Пауза на 50 %: телефон не ответил — запасной путь молчит, лимита там не бывает")
    func pauseBelowMinimumNeverFires() {
        var policy = ChargeDonePolicy()
        #expect(policy.evaluate(status(50, charging: true)) == .none)
        // Зарядка встала (нагрев), подтверждения нет — счётчик растёт, но уведомления нет.
        #expect(policy.evaluate(status(50)) == .needsConfirmation)
        #expect(policy.evaluate(status(50)) == .none)
        #expect(policy.evaluate(status(50)) == .none)
        #expect(policy.evaluate(status(50)) == .none)
        #expect(policy.fired == false)
        #expect(policy.stoppedPolls >= ChargeDonePolicy.fallbackPolls)
    }

    @Test("Подтверждённый лимит шлётся на любом проценте — порог 80 его не касается")
    func confirmedLimitFiresBelowMinimum() {
        var policy = ChargeDonePolicy()
        #expect(policy.evaluate(status(50, charging: true)) == .none)
        #expect(policy.evaluate(status(50)) == .needsConfirmation)
        #expect(policy.confirm(limitReached: true) == true)
        #expect(policy.fired == true)
        #expect(policy.evaluate(status(50)) == .none)
    }

    @Test("Воткнули при 85 с лимитом 80: зарядка не начинается — молчим всегда")
    func pluggedInAboveLimit() {
        var policy = ChargeDonePolicy()
        for _ in 0..<10 {
            #expect(policy.evaluate(status(85)) == .none)
        }
        #expect(policy.fired == false)
    }

    @Test("Сброс вручную обнуляет всё")
    func manualReset() {
        var policy = ChargeDonePolicy()
        #expect(policy.evaluate(status(80, charging: true)) == .none)
        #expect(policy.evaluate(status(80)) == .needsConfirmation)
        policy.reset()
        #expect(policy.sawCharging == false)
        #expect(policy.fired == false)
        #expect(policy.stoppedPolls == 0)
    }
}

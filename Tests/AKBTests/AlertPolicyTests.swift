import Foundation
import Testing

@Suite("Политика уведомлений о низком заряде")
struct AlertPolicyTests {

    private func status(_ percent: Int, charging: Bool = false) -> BatteryStatus {
        BatteryStatus(percent: percent, isCharging: charging)
    }

    @Test("Пересечение порога сверху вниз даёт ровно одно уведомление")
    func crossingThreshold() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: true)
        #expect(policy.evaluate(status(35)) == false)
        #expect(policy.evaluate(status(29)) == true)
        #expect(policy.evaluate(status(28)) == false)
        #expect(policy.evaluate(status(27)) == false)
    }

    @Test("Телефон уже ниже порога на первом же замере — уведомляем один раз")
    func alreadyLowAtLaunch() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: true)
        #expect(policy.evaluate(status(25)) == true)
        #expect(policy.evaluate(status(25)) == false)
        #expect(policy.evaluate(status(24)) == false)
    }

    @Test("Повтор на ступенях −10%: 30 → 20 → 10")
    func repeatsEveryTen() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: true)
        #expect(policy.evaluate(status(29)) == true)   // ступень 30
        #expect(policy.evaluate(status(22)) == false)
        #expect(policy.evaluate(status(19)) == true)   // ступень 20
        #expect(policy.evaluate(status(15)) == false)
        #expect(policy.evaluate(status(9)) == true)    // ступень 10
        #expect(policy.evaluate(status(3)) == false)
    }

    @Test("Без повторов уведомление только одно")
    func withoutRepeats() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: false)
        #expect(policy.evaluate(status(29)) == true)
        #expect(policy.evaluate(status(19)) == false)
        #expect(policy.evaluate(status(5)) == false)
    }

    @Test("Зарядка снимает взвод, после отключения уведомление приходит снова")
    func resetOnCharging() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: true)
        #expect(policy.evaluate(status(28)) == true)
        #expect(policy.evaluate(status(28, charging: true)) == false)
        #expect(policy.evaluate(status(28)) == true)
    }

    @Test("Возврат выше порога снимает взвод")
    func resetAboveThreshold() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: true)
        #expect(policy.evaluate(status(29)) == true)
        #expect(policy.evaluate(status(31)) == false)
        #expect(policy.evaluate(status(29)) == true)
    }

    @Test("Шум ±1% вокруг порога не даёт лишних уведомлений")
    func noiseAroundThreshold() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: true)
        #expect(policy.evaluate(status(29)) == true)
        #expect(policy.evaluate(status(30)) == false)  // взвод снят
        #expect(policy.evaluate(status(29)) == true)   // и это честное новое пересечение
        #expect(policy.evaluate(status(29)) == false)
        #expect(policy.evaluate(status(28)) == false)
    }

    @Test("Ступени порога считаются по убыванию до нуля")
    func steps() {
        #expect(AlertPolicy(threshold: 30, repeatEveryTenPercent: true).steps == [30, 20, 10])
        #expect(AlertPolicy(threshold: 25, repeatEveryTenPercent: true).steps == [25, 15, 5])
        #expect(AlertPolicy(threshold: 30, repeatEveryTenPercent: false).steps == [30])
    }

    @Test("reset() возвращает политику во взведённое состояние")
    func explicitReset() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: true)
        #expect(policy.evaluate(status(20)) == true)
        policy.reset()
        #expect(policy.evaluate(status(20)) == true)
    }
}

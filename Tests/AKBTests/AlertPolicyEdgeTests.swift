import Foundation
import Testing
@testable import AKB

/// Крайние случаи политики уведомлений (дополняет AlertPolicyTests).
@Suite("Политика уведомлений: края")
struct AlertPolicyEdgeTests {

    private func status(_ percent: Int, charging: Bool = false) -> BatteryStatus {
        BatteryStatus(percent: percent, isCharging: charging)
    }

    @Test("Порог 0 — ступеней нет, уведомлений нет")
    func zeroThreshold() {
        var policy = AlertPolicy(threshold: 0, repeatEveryTenPercent: true)
        #expect(policy.steps.isEmpty)
        #expect(policy.evaluate(status(0)) == false)
        #expect(policy.evaluate(status(5)) == false)
    }

    @Test("Порог 100 с повторами — десять ступеней")
    func hundredThreshold() {
        var policy = AlertPolicy(threshold: 100, repeatEveryTenPercent: true)
        #expect(policy.steps == [100, 90, 80, 70, 60, 50, 40, 30, 20, 10])
        #expect(policy.evaluate(status(99)) == true)
        #expect(policy.evaluate(status(95)) == false)
        #expect(policy.evaluate(status(89)) == true)
    }

    @Test("Порог не кратен десяти: ступени идут до нуля, но не ниже")
    func oddThreshold() {
        #expect(AlertPolicy(threshold: 35, repeatEveryTenPercent: true).steps == [35, 25, 15, 5])
        #expect(AlertPolicy(threshold: 5, repeatEveryTenPercent: true).steps == [5])
        var policy = AlertPolicy(threshold: 5, repeatEveryTenPercent: true)
        #expect(policy.evaluate(status(4)) == true)
        #expect(policy.evaluate(status(0)) == false)
    }

    @Test("Резкое падение через несколько ступеней — ровно одно уведомление")
    func bigDrop() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: true)
        #expect(policy.evaluate(status(35)) == false)
        #expect(policy.evaluate(status(5)) == true)
        #expect(policy.evaluate(status(5)) == false)
        #expect(policy.evaluate(status(4)) == false)
    }

    @Test("Колебания внутри низкой зоны не спамят")
    func oscillationInLowZone() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: true)
        #expect(policy.evaluate(status(29)) == true)    // ступень 30
        #expect(policy.evaluate(status(15)) == true)    // ступень 20
        #expect(policy.evaluate(status(25)) == false)   // вернулись выше 20, но ниже 30
        #expect(policy.evaluate(status(15)) == false)   // ступень 20 уже была
        #expect(policy.evaluate(status(9)) == true)     // ступень 10
    }

    @Test("Восстановленное состояние продолжает с той же ступени")
    func restoredState() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: true, lastFiredStep: 30)
        #expect(policy.evaluate(status(25)) == false)
        #expect(policy.evaluate(status(19)) == true)
    }

    @Test("Зарядка выше порога тоже снимает взвод")
    func chargingAboveThreshold() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: true)
        #expect(policy.evaluate(status(25)) == true)
        #expect(policy.evaluate(status(60, charging: true)) == false)
        #expect(policy.evaluate(status(25)) == true)
    }

    @Test("Ровно на пороге — не ниже порога")
    func exactlyAtThreshold() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: false)
        #expect(policy.evaluate(status(30)) == false)
        #expect(policy.evaluate(status(29)) == true)
    }

    @Test("Тот же порог: смена повторов не даёт второго уведомления о том же заряде")
    func reconfiguredKeepsStep() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: true)
        #expect(policy.evaluate(status(25)) == true)
        // Так делает BatteryMonitor.settingsChanged() (план §4): порог тот же,
        // значит взвод переносится.
        var same = policy.reconfigured(threshold: 30, repeatEveryTenPercent: false)
        #expect(same.evaluate(status(25)) == false)
    }

    @Test("Другой порог — политика взводится заново")
    func reconfiguredReArmsOnNewThreshold() {
        var policy = AlertPolicy(threshold: 30, repeatEveryTenPercent: true)
        #expect(policy.evaluate(status(25)) == true)
        var moved = policy.reconfigured(threshold: 40, repeatEveryTenPercent: true)
        #expect(moved.evaluate(status(25)) == true)
    }
}

import Foundation
import Testing
@testable import AKB

@MainActor
@Suite("Пауза до следующего опроса")
struct PollDelayTests {

    @Test("После успеха — обычный интервал")
    func success() {
        #expect(BatteryMonitor.nextPollDelay(interval: 300, lastFailed: false) == 300)
    }

    @Test("После неудачи — минута вместо пяти")
    func failure() {
        #expect(BatteryMonitor.nextPollDelay(interval: 300, lastFailed: true) == 60)
    }

    @Test("Короткий интервал неудача не удлиняет")
    func shortInterval() {
        #expect(BatteryMonitor.nextPollDelay(interval: 30, lastFailed: true) == 30)
    }

    @Test("На питании — каждые 5 с вместо пяти минут")
    func onPower() {
        #expect(BatteryMonitor.nextPollDelay(interval: 300, lastFailed: false, isOnPower: true) == 5)
    }

    @Test("На питании неудача ничего не меняет")
    func onPowerAfterFailure() {
        #expect(BatteryMonitor.nextPollDelay(interval: 300, lastFailed: true, isOnPower: true) == 5)
    }

    @Test("Телефон не спит — каждые 5 с")
    func awake() {
        #expect(BatteryMonitor.nextPollDelay(interval: 300, lastFailed: false, isAwake: true) == 5)
    }

    @Test("Телефон не спит — 5 с и при коротком интервале")
    func awakeShortInterval() {
        #expect(BatteryMonitor.nextPollDelay(interval: 30, lastFailed: false, isAwake: true) == 5)
    }

    @Test("Не на питании — обычный интервал")
    func offPower() {
        #expect(BatteryMonitor.nextPollDelay(interval: 300, lastFailed: false, isOnPower: false) == 300)
    }
}

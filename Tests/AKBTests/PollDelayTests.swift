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

    @Test("На питании — каждые 15 с вместо пяти минут")
    func onPower() {
        #expect(BatteryMonitor.nextPollDelay(interval: 300, lastFailed: false, isOnPower: true) == 15)
    }

    @Test("На питании неудача ничего не меняет")
    func onPowerAfterFailure() {
        #expect(BatteryMonitor.nextPollDelay(interval: 300, lastFailed: true, isOnPower: true) == 15)
    }

    @Test("Не на питании — обычный интервал")
    func offPower() {
        #expect(BatteryMonitor.nextPollDelay(interval: 300, lastFailed: false, isOnPower: false) == 300)
    }
}

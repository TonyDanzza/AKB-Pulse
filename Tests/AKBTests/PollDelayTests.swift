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
}

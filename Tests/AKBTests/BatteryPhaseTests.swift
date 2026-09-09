import Foundation
import Testing
@testable import AKB

private func status(_ percent: Int, ageMinutes: Double, now: Date) -> BatteryStatus {
    BatteryStatus(percent: percent,
                  isCharging: false,
                  externalConnected: false,
                  fullyCharged: false,
                  updatedAt: now.addingTimeInterval(-ageMinutes * 60))
}

@MainActor
@Suite("Возраст показаний")
struct BatteryPhaseTests {

    let now = Date(timeIntervalSince1970: 1_000_000)

    private func next(age: Double, failures: Int = 3, current: BatteryMonitor.Phase? = nil) -> BatteryMonitor.Phase {
        let last = status(74, ageMinutes: age, now: now)
        return BatteryMonitor.nextPhase(current: current ?? .ready(last),
                                        error: .deviceUnreachable("UDID"),
                                        lastKnown: last,
                                        now: now,
                                        noLinkAfter: BatteryMonitor.defaultNoLinkAfter,
                                        staleLimit: BatteryMonitor.defaultStaleLimit,
                                        failures: failures)
    }

    @Test("Пара пропущенных волн ничего не меняет")
    func shortMiss() {
        #expect(next(age: 1, failures: 1).status?.percent == 74)
        #expect(next(age: 1).isStale == false)
    }

    @Test("Моложе 15 минут — число остаётся живым")
    func fresh() {
        let phase = next(age: 14)
        #expect(phase.isStale == false)
        #expect(phase.isFailed == false)
        #expect(phase.status?.percent == 74)
    }

    @Test("Старше 15 минут — «Нет связи» с возрастом данных")
    func noLink() {
        let phase = next(age: 20)
        #expect(phase.isStale)
        #expect(phase.status?.percent == 74)
    }

    @Test("Старше 12 часов — пустое состояние")
    func tooOld() {
        #expect(next(age: 13 * 60).isFailed)
    }

    @Test("Сломанный инструмент — не сон, а ошибка")
    func brokenTool() {
        let last = status(74, ageMinutes: 1, now: now)
        let phase = BatteryMonitor.nextPhase(current: .ready(last),
                                             error: .toolNotFound,
                                             lastKnown: last,
                                             now: now,
                                             staleLimit: BatteryMonitor.defaultStaleLimit,
                                             failures: 1)
        #expect(phase.isFailed)
    }

    @Test("Данных не было вовсе — сразу ошибка")
    func noData() {
        let phase = BatteryMonitor.nextPhase(current: .loading,
                                             error: .noDevice,
                                             lastKnown: nil,
                                             now: now,
                                             staleLimit: BatteryMonitor.defaultStaleLimit,
                                             failures: 1)
        #expect(phase.isFailed)
    }
}

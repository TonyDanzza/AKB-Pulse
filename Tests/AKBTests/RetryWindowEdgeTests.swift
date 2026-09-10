import Foundation
import Testing

private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 0)
    private(set) var slept: [TimeInterval] = []
    func now() -> Date { lock.withLock { date } }
    func sleep(_ seconds: TimeInterval) {
        lock.withLock {
            slept.append(seconds)
            date = date.addingTimeInterval(seconds)
        }
    }
}

@Suite("Окно повторов: края")
struct RetryWindowEdgeTests {

    @Test("Отмена задачи во сне — бросается последняя ошибка попытки")
    func cancellationRethrowsLastError() async {
        let clock = StepClock()
        let window = RetryWindow(window: 40, interval: 3)
        var attempts = 0
        do {
            _ = try await window.run(now: clock.now, sleep: { _ in throw CancellationError() }) { _ in
                attempts += 1
                throw ProviderError.deviceUnreachable("UDID")
            }
            Issue.record("должна быть ошибка")
        } catch {
            #expect(error as? ProviderError == .deviceUnreachable("UDID"))
        }
        #expect(attempts == 1)
    }

    @Test("Отмена до первой попытки (порт закрыт) — таймаут")
    func cancellationBeforeAnyAttempt() async {
        let clock = StepClock()
        let window = RetryWindow(window: 40, interval: 3, probeInterval: 2)
        var attempts = 0
        do {
            _ = try await window.run(now: clock.now,
                                     sleep: { _ in throw CancellationError() },
                                     precheck: { false }) { _ in
                attempts += 1
                return 1
            }
            Issue.record("должна быть ошибка")
        } catch {
            #expect(error as? ProviderError == .timeout)
        }
        #expect(attempts == 0)
    }

    @Test("Порт открыт, но чтение не удалось — шаг остаётся шагом предпроверки")
    func failedBodyAfterOpenPortUsesProbeInterval() async throws {
        let clock = StepClock()
        let window = RetryWindow(window: 40, interval: 3, probeInterval: 2)
        var attempts = 0
        let value = try await window.run(now: clock.now, sleep: clock.sleep, precheck: { true }) { attempt in
            attempts += 1
            guard attempt == 2 else { throw ProviderError.deviceUnreachable("UDID") }
            return 74
        }
        #expect(value == 74)
        #expect(attempts == 3)
        #expect(clock.slept == [2, 2])
    }

    @Test("Без предпроверки шаг — interval")
    func withoutPrecheckUsesInterval() async throws {
        let clock = StepClock()
        let window = RetryWindow(window: 40, interval: 3, probeInterval: 2)
        _ = try await window.run(now: clock.now, sleep: clock.sleep) { attempt in
            guard attempt == 2 else { throw ProviderError.timeout }
            return 1
        }
        #expect(clock.slept == [3, 3])
    }

    @Test("Нулевое окно — одна попытка, без сна")
    func zeroWindow() async {
        let clock = StepClock()
        let window = RetryWindow(window: 0, interval: 3)
        var attempts = 0
        _ = try? await window.run(now: clock.now, sleep: clock.sleep) { _ in
            attempts += 1
            throw ProviderError.timeout
        }
        #expect(attempts == 1)
        #expect(clock.slept.isEmpty)
    }

    @Test("Номера попыток идут подряд с нуля")
    func attemptNumbers() async {
        let clock = StepClock()
        let window = RetryWindow(window: 10, interval: 3)
        var seen: [Int] = []
        _ = try? await window.run(now: clock.now, sleep: clock.sleep) { attempt in
            seen.append(attempt)
            throw ProviderError.timeout
        }
        #expect(seen == [0, 1, 2, 3])
    }

    @Test("Ошибка не из ProviderError доходит до вызывающего как есть")
    func foreignErrorPassesThrough() async {
        struct Boom: Error {}
        let clock = StepClock()
        let window = RetryWindow(window: 0, interval: 3)
        do {
            _ = try await window.run(now: clock.now, sleep: clock.sleep) { _ in throw Boom() }
            Issue.record("должна быть ошибка")
        } catch {
            #expect(error is Boom)
        }
    }
}

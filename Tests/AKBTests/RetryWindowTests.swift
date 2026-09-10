import Foundation
import Testing

/// Ненастоящие часы: «сон» просто двигает стрелки, поэтому тест окна 40 с идёт мгновенно.
private final class FakeClock: @unchecked Sendable {
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

@Suite("Окно повторов")
struct RetryWindowTests {

    @Test("Успех с первой попытки — без сна")
    func firstTry() async throws {
        let clock = FakeClock()
        let window = RetryWindow(window: 40, interval: 3)
        var attempts = 0
        let value = try await window.run(now: clock.now, sleep: clock.sleep) { _ in
            attempts += 1
            return 74
        }
        #expect(value == 74)
        #expect(attempts == 1)
        #expect(clock.slept.isEmpty)
    }

    @Test("Телефон отвечает волной на пятой попытке — окно прекращается сразу")
    func succeedsLater() async throws {
        let clock = FakeClock()
        let window = RetryWindow(window: 40, interval: 3)
        var attempts = 0
        let value = try await window.run(now: clock.now, sleep: clock.sleep) { attempt in
            attempts += 1
            guard attempt == 4 else { throw ProviderError.deviceUnreachable("UDID") }
            return 74
        }
        #expect(value == 74)
        #expect(attempts == 5)
        #expect(clock.slept.count == 4)
        #expect(clock.now().timeIntervalSince1970 == 12)
    }

    @Test("Окно 40 с с шагом 3 с: 14 попыток, потом последняя ошибка")
    func exhausts() async {
        let clock = FakeClock()
        let window = RetryWindow(window: 40, interval: 3)
        var attempts = 0
        do {
            _ = try await window.run(now: clock.now, sleep: clock.sleep) { _ in
                attempts += 1
                throw ProviderError.deviceUnreachable("UDID")
            }
            Issue.record("окно должно было закончиться ошибкой")
        } catch {
            #expect(error as? ProviderError == .deviceUnreachable("UDID"))
        }
        // Попытки на 0, 3, … 39 с — 14 штук; на 42 с уже не влезаем.
        #expect(attempts == 14)
        #expect(clock.now().timeIntervalSince1970 == 39)
    }

    @Test("Окно короче шага — ровно одна попытка")
    func singleAttempt() async {
        let clock = FakeClock()
        let window = RetryWindow(window: 2, interval: 3)
        var attempts = 0
        _ = try? await window.run(now: clock.now, sleep: clock.sleep) { _ in
            attempts += 1
            throw ProviderError.timeout
        }
        #expect(attempts == 1)
        #expect(clock.slept.isEmpty)
    }

    @Test("Предпроверка порта: пока порт закрыт, полное чтение не запускается")
    func precheckSkipsBody() async {
        let clock = FakeClock()
        let window = RetryWindow(window: 40, interval: 3, probeInterval: 2)
        var probes = 0
        var attempts = 0
        let value = try? await window.run(now: clock.now, sleep: clock.sleep, precheck: {
            probes += 1
            return probes >= 4          // волна пришла на четвёртой проверке
        }) { _ in
            attempts += 1
            return 74
        }
        #expect(value == 74)
        #expect(attempts == 1)
        #expect(probes == 4)
        // Три сна по 2 с — шаг предпроверки, а не шаг попытки.
        #expect(clock.slept == [2, 2, 2])
    }

    @Test("Порт закрыт всё окно: 21 проверка по 2 с и ни одной попытки")
    func precheckExhausts() async {
        let clock = FakeClock()
        let window = RetryWindow(window: 40, interval: 3, probeInterval: 2)
        var probes = 0
        var attempts = 0
        do {
            _ = try await window.run(now: clock.now, sleep: clock.sleep, precheck: {
                probes += 1
                return false
            }) { _ in
                attempts += 1
                throw ProviderError.deviceUnreachable("UDID")
            }
            Issue.record("окно должно было закончиться ошибкой")
        } catch {
            #expect(error as? ProviderError == .timeout)
        }
        #expect(attempts == 0)
        // Проверки на 0, 2, … 40 с — вдвое чаще, чем были бы попытки с шагом 3 с.
        #expect(probes == 21)
        #expect(clock.now().timeIntervalSince1970 == 40)
    }
}

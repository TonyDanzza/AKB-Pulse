import Foundation

/// Окно повторов: спящий iPhone держит порт lockdownd открытым волнами —
/// 5–15 секунд отвечает, 10–30 молчит (план §16.1). Один запрос почти всегда
/// промахивается, поэтому прямое чтение повторяется каждые `interval`
/// в течение `window` и возвращает первый успех.
struct RetryWindow: Sendable {

    /// Значения из наблюдений за живым телефоном: за 40 с волна успевает прийти.
    var window: TimeInterval = 40
    var interval: TimeInterval = 3

    /// Выполняет `body`, пока оно не удастся или пока не кончится окно.
    /// Часы и сон инжектируются, чтобы тест шёл мгновенно.
    /// Возвращает результат первой удачной попытки; иначе бросает последнюю ошибку.
    func run<T>(now: () -> Date = { Date() },
                sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                body: (Int) async throws -> T) async throws -> T {
        let start = now()
        var attempt = 0
        var lastError: Error = ProviderError.timeout
        while true {
            do {
                return try await body(attempt)
            } catch {
                lastError = error
            }
            attempt += 1
            // Спать имеет смысл, только если после сна останется время на попытку.
            guard now().timeIntervalSince(start) + interval <= window else { throw lastError }
            do {
                try await sleep(interval)
            } catch {
                throw lastError   // окно отменили вместе с задачей
            }
        }
    }
}

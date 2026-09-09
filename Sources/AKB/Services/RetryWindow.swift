import Foundation

/// Окно повторов: спящий iPhone держит порт lockdownd открытым волнами —
/// 5–15 секунд отвечает, 10–30 молчит (план §16.1). Один запрос почти всегда
/// промахивается, поэтому прямое чтение повторяется каждые `interval`
/// в течение `window` и возвращает первый успех.
struct RetryWindow: Sendable {

    /// Значения из наблюдений за живым телефоном: за 40 с волна успевает прийти.
    var window: TimeInterval = 40
    var interval: TimeInterval = 3
    /// Шаг дешёвой предпроверки: стучаться в закрытый порт можно чаще, чем
    /// запускать полное чтение заряда (план §23.1).
    var probeInterval: TimeInterval = 2

    /// Выполняет `body`, пока оно не удастся или пока не кончится окно.
    /// Часы и сон инжектируются, чтобы тест шёл мгновенно.
    ///
    /// `precheck` — необязательная дешёвая проверка «телефон сейчас слушает?».
    /// Пока она отвечает «нет», `body` не запускается вовсе, а шаг между
    /// попытками равен `probeInterval`: за то же окно проверок выходит больше,
    /// и волна ответа реже пропускается.
    ///
    /// Возвращает результат первой удачной попытки; иначе бросает последнюю ошибку.
    func run<T>(now: () -> Date = { Date() },
                sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                precheck: (() async -> Bool)? = nil,
                body: (Int) async throws -> T) async throws -> T {
        let start = now()
        var attempt = 0
        var lastError: Error = ProviderError.timeout
        while true {
            var pause = interval
            if let precheck, await precheck() == false {
                pause = probeInterval          // порт закрыт, полное чтение не нужно
            } else {
                do {
                    return try await body(attempt)
                } catch {
                    lastError = error
                }
                attempt += 1
                if precheck != nil { pause = probeInterval }
            }
            // Спать имеет смысл, только если после сна останется время на попытку.
            guard now().timeIntervalSince(start) + pause <= window else { throw lastError }
            do {
                try await sleep(pause)
            } catch {
                throw lastError   // окно отменили вместе с задачей
            }
        }
    }
}

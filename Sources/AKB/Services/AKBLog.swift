import Foundation
import OSLog

/// Единая точка логирования (план §19.1): одна и та же строка уходит
/// и в `os.Logger` (unified log, как раньше), и в файл `~/Library/Logs/AKB/akb.log`.
///
/// Строки и раньше были `.public` — в файл они пишутся как есть. Там имя телефона,
/// его UDID и адрес в домашней сети; это осознанно, файл нужен именно для поддержки
/// (отмечено в README и в подсказке под кнопкой в настройках).
enum AKBLog {

    /// Категории те же, что были у отдельных `Logger` в сервисах.
    enum Category: String, Sendable, CaseIterable {
        case app
        case monitor
        case provider
        case resolver
        case events
    }

    static let subsystem = "ru.tonydanzza.akb"

    // MARK: - Запись

    static func info(_ category: Category, _ message: String) {
        logger(for: category).info("\(message, privacy: .public)")
        enqueue(FileLog.line(date: Date(), category: category.rawValue, message: message))
    }

    static func debug(_ category: Category, _ message: String) {
        logger(for: category).debug("\(message, privacy: .public)")
        enqueue(FileLog.line(date: Date(), category: category.rawValue, message: message))
    }

    /// Шапка запуска: версия, система, где лежит приложение, помощники, настройки.
    /// Пишется только в файл — в unified log эти сведения не нужны.
    static func startSession() {
        logger(for: .app).info("запуск")
        enqueue(SupportReport.header(now: Date()))
    }

    /// Дожидается, пока всё записанное окажется в файле. Нужно перед сборкой отчёта.
    static func flush() async {
        await tailTask().value
    }

    // MARK: - Внутреннее

    private static let loggers: [Category: Logger] = Dictionary(
        uniqueKeysWithValues: Category.allCases.map {
            ($0, Logger(subsystem: subsystem, category: $0.rawValue))
        }
    )

    private static func logger(for category: Category) -> Logger {
        loggers[category] ?? Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// Порядок строк в файле должен совпадать с порядком вызовов, поэтому записи
    /// выстраиваются в цепочку: каждая ждёт предыдущую. Актор сам по себе порядок
    /// не держит — задачи к нему попадают как повезёт.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tail: Task<Void, Never> = Task {}

    private static func enqueue(_ line: String) {
        lock.lock()
        let previous = tail
        tail = Task {
            await previous.value
            await FileLog.shared.append(line)
        }
        lock.unlock()
    }

    private static func tailTask() -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        return tail
    }
}

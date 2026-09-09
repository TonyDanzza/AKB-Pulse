import Foundation

/// Отчёт для поддержки (план §19.2): один текстовый файл, который человек
/// сохраняет кнопкой в настройках и присылает тому, кто помогает с настройкой.
///
/// Состав: шапка (что за машина и какая версия) + файловый лог целиком,
/// от старого файла к новому + хвост unified log за последние два часа.
enum SupportReport {

    /// Сколько истории unified log просить у системы.
    static let unifiedLogWindow = "2h"
    /// `log show` на холодном кэше думает долго; ждать дольше незачем — шапка
    /// и файловый лог в отчёте уже есть.
    static let unifiedLogTimeout: TimeInterval = 15

    // MARK: - Шапка

    static func header(now: Date) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return """
            ===== АКБ =====
            Дата: \(FileLog.timestamp(now))
            Версия: \(version) (\(build))
            macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
            Mac: \(hardwareModel())
            Приложение: \(bundle.bundleURL.path)
            Помощники: \(toolsDescription())
            Интервал опроса: \(Prefs.pollInterval) с
            Порог тревоги: \(Prefs.lowThreshold)%
            ===============
            """
    }

    /// `sysctl hw.model` без запуска процесса.
    static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "?" }
        // sysctl отдаёт строку с нулём на конце — его в String тащить не надо.
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    /// Откуда взяты `ideviceinfo` и `akb-direct` — первая причина, по которой
    /// у друга ничего не работает.
    static func toolsDescription() -> String {
        guard let directory = ToolLocator.resolvedDirectory else {
            return "не найдены (нет ideviceinfo)"
        }
        let origin = ToolLocator.isBundled ? "встроены в бандл" : "из системы"
        let direct = ToolLocator.locate("akb-direct") == nil ? ", akb-direct отсутствует" : ""
        return "\(origin): \(directory)\(direct)"
    }

    // MARK: - Сборка файла

    /// Чистая склейка: шапка, файлы лога от старого к новому, хвост unified log.
    static func build(header: String,
                      logDirectory: URL,
                      unifiedLog: String,
                      keep: Int = FileLog.defaultKeep) -> String {
        var parts = [header]
        let files = FileLog.filesOldestFirst(in: logDirectory, keep: keep)
        if files.isEmpty {
            parts.append("--- \(logFileTitle) ---\nПусто: приложение ещё ничего не записало.")
        } else {
            for url in files {
                let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? "(файл не читается)"
                parts.append("--- \(logFileTitle): \(url.lastPathComponent) ---\n"
                             + contents.trimmingCharacters(in: .newlines))
            }
        }
        parts.append("--- unified log (\(unifiedLogWindow)) ---\n"
                     + unifiedLog.trimmingCharacters(in: .newlines))
        return parts.joined(separator: "\n\n") + "\n"
    }

    private static let logFileTitle = "файловый лог"

    /// Полный отчёт: дожидается записи всего накопленного, читает файлы и
    /// спрашивает систему про unified log.
    static func make(now: Date = Date(),
                     logDirectory: URL? = nil) async -> String {
        await AKBLog.flush()
        let directory = logDirectory ?? FileLog.shared.directory
        return build(header: header(now: now),
                     logDirectory: directory,
                     unifiedLog: await unifiedLogTail())
    }

    /// `log show --info --last 2h --predicate 'subsystem == "ru.tonydanzza.akb"'`.
    /// Не получилось — так и пишем, отчёт от этого не пропадает.
    static func unifiedLogTail() async -> String {
        let arguments = [
            "show",
            "--info",
            "--last", unifiedLogWindow,
            "--predicate", "subsystem == \"\(AKBLog.subsystem)\""
        ]
        guard let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/log"),
                                                        arguments: arguments,
                                                        timeout: unifiedLogTimeout),
              result.status == 0 else {
            return "unified log недоступен"
        }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "unified log недоступен" : text
    }

    // MARK: - Имя файла

    /// `АКБ-лог-2026-09-09-1803.txt`.
    static func suggestedFileName(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "АКБ-лог-\(formatter.string(from: now)).txt"
    }
}

import Foundation

/// Файловый лог в `~/Library/Logs/AKB/` (план §19.1).
///
/// Зачем: приложение раздаётся друзьям, а `os.Logger` пишет только в unified log,
/// откуда обычный человек ничего не достанет. Те же строки дублируются в текстовый
/// файл, который потом уходит в отчёт для поддержки (`SupportReport`).
///
/// Ротация: файл вырос больше `maxBytes` → `akb.log` становится `akb.1.log`,
/// всего хранится `keep` файлов. Любая ошибка записи глотается: лог не имеет
/// права ронять приложение или мешать опросу.
actor FileLog {

    static let shared = FileLog()

    /// 2 МБ — примерно неделя обычной работы при опросе раз в минуту.
    static let defaultMaxBytes = 2 * 1024 * 1024
    /// `akb.log`, `akb.1.log`, `akb.2.log`.
    static let defaultKeep = 3

    static var defaultDirectory: URL {
        // Тесты гоняют те же сервисы, что и приложение, и без этой оговорки
        // засоряли бы настоящий лог пользователя своими выдуманными адресами.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("AKB-tests-log", isDirectory: true)
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("AKB", isDirectory: true)
    }

    let directory: URL
    private let maxBytes: Int
    private let keep: Int

    init(directory: URL = FileLog.defaultDirectory,
         maxBytes: Int = FileLog.defaultMaxBytes,
         keep: Int = FileLog.defaultKeep) {
        self.directory = directory
        self.maxBytes = max(1, maxBytes)
        self.keep = max(1, keep)
    }

    // MARK: - Имена файлов

    /// `akb.log` для нулевого индекса, `akb.1.log` и дальше для архивных.
    static func fileName(index: Int) -> String {
        index == 0 ? "akb.log" : "akb.\(index).log"
    }

    var currentURL: URL { url(index: 0) }

    nonisolated func url(index: Int) -> URL {
        directory.appendingPathComponent(Self.fileName(index: index))
    }

    /// Существующие файлы лога от старого к новому — в таком порядке они и
    /// склеиваются в отчёт (план §19.2).
    nonisolated func filesOldestFirst() -> [URL] {
        Self.filesOldestFirst(in: directory, keep: keep)
    }

    static func filesOldestFirst(in directory: URL, keep: Int = FileLog.defaultKeep) -> [URL] {
        let fm = FileManager.default
        return (0..<max(1, keep)).reversed()
            .map { directory.appendingPathComponent(fileName(index: $0)) }
            .filter { fm.fileExists(atPath: $0.path) }
    }

    // MARK: - Строка лога

    /// `2026-09-09 18:03:38.785 [provider] заряд 67% путём direct`.
    static func line(date: Date, category: String, message: String) -> String {
        "\(timestamp(date)) [\(category)] \(message)"
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func timestamp(_ date: Date) -> String {
        formatter.string(from: date)
    }

    // MARK: - Запись

    /// Дописывает строку (многострочные сообщения складываются как есть) и,
    /// если файл перерос предел, крутит ротацию.
    func append(_ line: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = currentURL
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            var size: UInt64 = 0
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data((line + "\n").utf8))
                size = try handle.offset()
            } catch {
                // Записать не вышло — файл всё равно закрываем ниже.
            }
            try? handle.close()
            if size >= UInt64(maxBytes) { rotate() }
        } catch {
            // Лог не должен ронять приложение (план §19.1).
        }
    }

    /// `akb.2.log` исчезает, `akb.1.log` → `akb.2.log`, `akb.log` → `akb.1.log`.
    private func rotate() {
        let fm = FileManager.default
        try? fm.removeItem(at: url(index: keep - 1))
        for index in stride(from: keep - 2, through: 0, by: -1) {
            let source = url(index: index)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = url(index: index + 1)
            try? fm.removeItem(at: destination)
            try? fm.moveItem(at: source, to: destination)
        }
    }
}

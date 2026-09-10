import Foundation
import Testing
@testable import AKB

@Suite("Файловый лог: края")
struct FileLogEdgeTests {

    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("akb-edge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Каталог нельзя создать — запись молча пропускается")
    func unwritableDirectory() async throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appendingPathComponent("plain-file")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        // Каталог «внутри» обычного файла создать невозможно.
        let log = FileLog(directory: file.appendingPathComponent("logs", isDirectory: true))
        await log.append("строка")
        #expect(try String(contentsOf: file, encoding: .utf8) == "x")
    }

    @Test("Многострочное сообщение пишется целиком")
    func multilineMessage() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileLog(directory: directory)
        await log.append("первая\n    вторая")
        await log.append("третья")
        let text = try String(contentsOf: directory.appendingPathComponent("akb.log"), encoding: .utf8)
        #expect(text == "первая\n    вторая\nтретья\n")
    }

    @Test("keep = 1: архивов нет, переполненный файл просто начинается заново")
    func keepOne() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileLog(directory: directory, maxBytes: 100, keep: 1)
        for index in 0..<10 {
            await log.append("\(index) " + String(repeating: "x", count: 40))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.allSatisfy { $0 == "akb.log" })
        #expect(files.count <= 1)
    }

    @Test("Список файлов идёт от старого к новому и не выходит за keep")
    func filesOrder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["akb.log", "akb.1.log", "akb.2.log", "akb.3.log"] {
            try "x".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let names = FileLog.filesOldestFirst(in: directory, keep: 3).map(\.lastPathComponent)
        #expect(names == ["akb.2.log", "akb.1.log", "akb.log"])
        #expect(FileLog.filesOldestFirst(in: directory, keep: 1).map(\.lastPathComponent) == ["akb.log"])
    }

    @Test("Имена файлов")
    func fileNames() {
        #expect(FileLog.fileName(index: 0) == "akb.log")
        #expect(FileLog.fileName(index: 1) == "akb.1.log")
        #expect(FileLog.fileName(index: 7) == "akb.7.log")
    }

    @Test("Отметка времени — фиксированный формат")
    func timestampFormat() {
        let stamp = FileLog.timestamp(Date(timeIntervalSince1970: 0))
        #expect(stamp.count == "2026-09-09 18:03:38.785".count)
        #expect(stamp.wholeMatch(of: /\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}/) != nil)
    }

    @Test("Под тестами лог уходит во временную папку, а не в ~/Library/Logs/AKB")
    func testsDoNotTouchRealLog() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return }
        let path = FileLog.defaultDirectory.path
        #expect(!path.contains("/Library/Logs/AKB"))
        #expect(FileLog.shared.directory.path == path)
    }
}

@Suite("Единый лог AKBLog")
struct AKBLogTests {

    @Test("Строки попадают в файл в порядке вызовов")
    func preservesOrder() async throws {
        let marker = "ORDER-\(UUID().uuidString)"
        for index in 0..<200 {
            AKBLog.info(.app, "\(marker) \(index)")
        }
        await AKBLog.flush()
        let text = try String(contentsOf: FileLog.shared.url(index: 0), encoding: .utf8)
        let numbers = text.split(separator: "\n")
            .filter { $0.contains(marker) }
            .compactMap { Int($0.split(separator: " ").last ?? "") }
        #expect(numbers == Array(0..<200))
    }

    @Test("Параллельные вызовы из разных задач ничего не теряют")
    func concurrentWritersLoseNothing() async throws {
        let marker = "PAR-\(UUID().uuidString)"
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask { AKBLog.debug(.monitor, "\(marker) \(index)") }
            }
        }
        await AKBLog.flush()
        let text = try String(contentsOf: FileLog.shared.url(index: 0), encoding: .utf8)
        let count = text.split(separator: "\n").filter { $0.contains(marker) }.count
        #expect(count == 50)
    }

    @Test("Категория попадает в строку")
    func categoryInLine() async throws {
        let marker = "CAT-\(UUID().uuidString)"
        AKBLog.info(.resolver, marker)
        await AKBLog.flush()
        let text = try String(contentsOf: FileLog.shared.url(index: 0), encoding: .utf8)
        #expect(text.contains("[resolver] \(marker)"))
    }
}

@Suite("Отчёт для поддержки: края")
struct SupportReportEdgeTests {

    @Test("Пустой каталог лога — честная пометка вместо файлов")
    func emptyDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("akb-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = SupportReport.build(header: "H", logDirectory: directory, unifiedLog: "U")
        #expect(report.hasPrefix("H\n\n"))
        #expect(report.contains("Пусто"))
        #expect(report.hasSuffix("U\n"))
    }

    @Test("Нечитаемый файл лога не срывает отчёт")
    func unreadableFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("akb-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0xff, 0xfe, 0xc0, 0x00]).write(to: directory.appendingPathComponent("akb.log"))
        let report = SupportReport.build(header: "H", logDirectory: directory, unifiedLog: "U")
        #expect(report.contains("akb.log"))
        #expect(report.contains("(файл не читается)"))
    }

    @Test("Имя файла отчёта")
    func fileName() {
        let name = SupportReport.suggestedFileName(now: Date())
        #expect(name.wholeMatch(of: /АКБ-лог-\d{4}-\d{2}-\d{2}-\d{4}\.txt/) != nil)
    }

    @Test("Модель Mac читается из sysctl")
    func hardwareModel() {
        let model = SupportReport.hardwareModel()
        #expect(model != "?")
        #expect(!model.isEmpty)
        #expect(!model.contains("\0"))
    }

    @Test("Шапка содержит все поля")
    func headerFields() {
        let header = SupportReport.header(now: Date(timeIntervalSince1970: 0))
        for field in ["Дата:", "Версия:", "macOS:", "Mac:", "Приложение:", "Помощники:", "Интервал опроса:", "Порог тревоги:"] {
            #expect(header.contains(field), "нет поля \(field)")
        }
    }
}

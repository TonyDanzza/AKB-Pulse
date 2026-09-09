import Foundation
import Testing
@testable import AKB

/// Файловый лог и отчёт для поддержки (план §19.3).
@Suite("Файловый лог")
struct FileLogTests {

    /// Свой каталог во временной папке: настоящий `~/Library/Logs/AKB` тесты не трогают.
    private func makeDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("akb-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Пока файл мал, ротации нет — всё в akb.log")
    func noRotationWhileSmall() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = FileLog(directory: directory, maxBytes: 1024, keep: 3)
        for index in 0..<5 {
            await log.append("строка \(index)")
        }

        let contents = try String(contentsOf: directory.appendingPathComponent("akb.log"), encoding: .utf8)
        #expect(contents.contains("строка 0"))
        #expect(contents.contains("строка 4"))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("akb.1.log").path))
    }

    @Test("Переполнение крутит файлы и хранит ровно три")
    func rotatesAndKeepsThree() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = FileLog(directory: directory, maxBytes: 1024, keep: 3)
        // Строка ~100 байт: на каждый килобайт приходится с десяток строк,
        // 200 строк гарантированно прокручивают все три файла не по разу.
        let padding = String(repeating: "x", count: 80)
        for index in 0..<200 {
            await log.append("\(index) \(padding)")
        }

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: directory.appendingPathComponent("akb.log").path))
        #expect(fm.fileExists(atPath: directory.appendingPathComponent("akb.1.log").path))
        #expect(fm.fileExists(atPath: directory.appendingPathComponent("akb.2.log").path))
        // Четвёртого файла быть не должно — он и есть «хранить 3».
        #expect(!fm.fileExists(atPath: directory.appendingPathComponent("akb.3.log").path))

        let files = try fm.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == 3)

        // Самые свежие строки — в akb.log, самые старые из хранимых — в akb.2.log.
        let current = try String(contentsOf: directory.appendingPathComponent("akb.log"), encoding: .utf8)
        let oldest = try String(contentsOf: directory.appendingPathComponent("akb.2.log"), encoding: .utf8)
        #expect(current.contains("199 "))
        #expect(!oldest.contains("199 "))
    }

    @Test("Строка лога: время, категория, сообщение")
    func lineFormat() {
        let date = Date(timeIntervalSince1970: 0)
        let line = FileLog.line(date: date, category: "provider", message: "заряд 67%")
        #expect(line.hasSuffix(" [provider] заряд 67%"))
        #expect(line.count > " [provider] заряд 67%".count)
    }
}

@Suite("Отчёт для поддержки")
struct SupportReportTests {

    @Test("В отчёте есть шапка, файлы лога от старого к новому и unified log")
    func buildsReport() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("akb-report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try "самое старое".write(to: directory.appendingPathComponent("akb.2.log"),
                                 atomically: true, encoding: .utf8)
        try "середина".write(to: directory.appendingPathComponent("akb.1.log"),
                             atomically: true, encoding: .utf8)
        try "самое свежее".write(to: directory.appendingPathComponent("akb.log"),
                                 atomically: true, encoding: .utf8)

        let report = SupportReport.build(header: SupportReport.header(now: Date()),
                                         logDirectory: directory,
                                         unifiedLog: "хвост unified log")

        #expect(report.contains("===== АКБ ====="))
        #expect(report.contains("macOS: "))
        #expect(report.contains("Mac: "))
        #expect(report.contains("Интервал опроса:"))
        #expect(report.contains("хвост unified log"))

        let old = try #require(report.range(of: "самое старое"))
        let middle = try #require(report.range(of: "середина"))
        let fresh = try #require(report.range(of: "самое свежее"))
        #expect(old.lowerBound < middle.lowerBound)
        #expect(middle.lowerBound < fresh.lowerBound)
    }
}

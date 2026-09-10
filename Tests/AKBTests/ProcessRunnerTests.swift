import Foundation
import Testing
@testable import AKB

/// Настоящие процессы: короткие системные утилиты из /bin и /usr/bin.
@Suite("Запуск внешних процессов")
struct ProcessRunnerTests {

    private let sh = URL(fileURLWithPath: "/bin/sh")

    @Test("stdout, stderr и код возврата приходят целиком")
    func capturesEverything() async throws {
        let result = try await ProcessRunner.run(sh, arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 5)
        #expect(result.status == 3)
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
    }

    @Test("Большой вывод не блокирует процесс")
    func largeOutput() async throws {
        let result = try await ProcessRunner.run(sh, arguments: ["-c", "yes | head -c 300000"], timeout: 10)
        #expect(result.status == 0)
        #expect(result.stdout.utf8.count == 300_000)
    }

    @Test("Таймаут: процесс убивается, ошибка .timeout, ждём не дольше пары секунд")
    func timeoutKills() async {
        let started = ContinuousClock.now
        await #expect(throws: ProviderError.timeout) {
            _ = try await ProcessRunner.run(sh, arguments: ["-c", "sleep 30"], timeout: 0.3)
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(5))
    }

    @Test("Несуществующий исполняемый файл — .toolNotFound")
    func missingExecutable() async {
        await #expect(throws: ProviderError.toolNotFound) {
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/akb-tool"), arguments: [], timeout: 5)
        }
    }

    @Test("Пустой вывод — пустые строки, не мусор")
    func emptyOutput() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [], timeout: 5)
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
    }

    @Test("Процесс, который закрыл stdout и висит, всё равно упирается в таймаут")
    func closedStdoutStillTimesOut() async {
        await #expect(throws: ProviderError.timeout) {
            _ = try await ProcessRunner.run(sh, arguments: ["-c", "exec >&-; sleep 30"], timeout: 0.3)
        }
    }

    @Test("Несколько запусков параллельно не мешают друг другу")
    func parallelRuns() async throws {
        try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<8 {
                group.addTask {
                    try await ProcessRunner.run(sh, arguments: ["-c", "echo \(index)"], timeout: 5).stdout
                }
            }
            var outputs: Set<String> = []
            for try await output in group { outputs.insert(output) }
            #expect(outputs == Set((0..<8).map { "\($0)\n" }))
        }
    }
}

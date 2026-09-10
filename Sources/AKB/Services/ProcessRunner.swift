import Foundation

/// Результат запуска внешней утилиты.
struct ProcessResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// Обёртка над `Process`, которая никогда не выполняется на главном потоке
/// и жёстко ограничена таймаутом (план §3, §6).
enum ProcessRunner {

    /// Маленький контейнер, чтобы переносить не-Sendable типы между очередями.
    private final class UnsafeBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func set(_ data: Data) { lock.lock(); storage = data; lock.unlock() }
        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: storage, as: UTF8.self)
        }
    }

    static func run(_ executable: URL,
                    arguments: [String],
                    timeout: TimeInterval = 10) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = ProcessInfo.processInfo.environment

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ProviderError.toolNotFound)
                    return
                }

                // Читаем оба пайпа параллельно, иначе большой вывод заблокирует процесс.
                let outBox = DataBox()
                let errBox = DataBox()
                let outHandle = UnsafeBox(outPipe.fileHandleForReading)
                let errHandle = UnsafeBox(errPipe.fileHandleForReading)
                let readers = DispatchGroup()

                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    outBox.set(outHandle.value.readDataToEndOfFile())
                    readers.leave()
                }
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBox.set(errHandle.value.readDataToEndOfFile())
                    readers.leave()
                }

                if finished.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    // SIGTERM можно игнорировать: такой процесс переживёт таймаут,
                    // удержит наши концы пайпов и оставит два чтения висеть навсегда.
                    // Поэтому добиваем (план §1).
                    if finished.wait(timeout: .now() + 1) == .timedOut {
                        kill(process.processIdentifier, SIGKILL)
                        _ = finished.wait(timeout: .now() + 2)
                    }
                    _ = readers.wait(timeout: .now() + 2)
                    continuation.resume(throwing: ProviderError.timeout)
                    return
                }

                _ = readers.wait(timeout: .now() + 2)
                continuation.resume(returning: ProcessResult(
                    status: process.terminationStatus,
                    stdout: outBox.text,
                    stderr: errBox.text
                ))
            }
        }
    }
}

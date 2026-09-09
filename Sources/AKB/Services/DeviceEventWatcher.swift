import Foundation
import OSLog

/// Слушает события usbmuxd через помощник `akb-direct watch` и дёргает опрос
/// сразу, как телефон появился или пропал (план §18.1).
///
/// Зачем: подключение зарядки будит телефон, он объявляется в usbmuxd — это
/// самый ранний сигнал «состояние изменилось». Без него статус «Заряжается»
/// появлялся и пропадал с опозданием до двух минут.
@MainActor
final class DeviceEventWatcher {

    static let log = Logger(subsystem: "ru.tonydanzza.akb", category: "events")

    /// События приходят пачкой (телефон объявляется сразу по нескольким
    /// транспортам) — опрос делаем один, через паузу.
    static let debounce: Duration = .seconds(2)
    /// Помощник упал — поднимаем заново, но не в цикле без передышки.
    static let restartDelay: Duration = .seconds(5)

    private weak var monitor: BatteryMonitor?
    private var supervisor: Task<Void, Never>?
    private var pokeTask: Task<Void, Never>?
    private var process: Process?

    init(monitor: BatteryMonitor) {
        self.monitor = monitor
    }

    // MARK: - Жизненный цикл

    func start() {
        // В фейковом режиме телефона нет, слушать нечего (план §18.1).
        guard !FakeMode.isActive, supervisor == nil else { return }
        supervisor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let launched = await self.runOnce()
                guard launched, !Task.isCancelled else { return }
                try? await Task.sleep(for: Self.restartDelay)
            }
        }
    }

    func stop() {
        supervisor?.cancel()
        supervisor = nil
        pokeTask?.cancel()
        pokeTask = nil
        process?.terminate()
        process = nil
    }

    // MARK: - Помощник

    /// Один запуск `akb-direct watch`: живёт, пока помощник не умрёт.
    /// Возвращает `false`, если поднимать заново бессмысленно (нет помощника).
    private func runOnce() async -> Bool {
        guard let tool = ToolLocator.locate("akb-direct") else {
            Self.log.info("akb-direct не найден, события usbmuxd недоступны")
            return false
        }

        let process = Process()
        process.executableURL = tool
        process.arguments = ["watch"]
        let output = Pipe()
        // Свой stdin, а не /dev/null: помощник ждёт на нём EOF и уходит
        // вместе с приложением, если то умрёт, не закрыв процесс.
        let input = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = input

        let buffer = LineBuffer()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let lines = buffer.append(data)
            guard !lines.isEmpty else { return }
            Task { @MainActor in
                for line in lines { self?.handle(line) }
            }
        }

        self.process = process
        Self.log.info("слушаю события usbmuxd")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OnceFlag()
            process.terminationHandler = { _ in
                if once.take() { continuation.resume() }
            }
            do {
                try process.run()
            } catch {
                Self.log.info("не удалось запустить akb-direct watch: \(String(describing: error), privacy: .public)")
                if once.take() { continuation.resume() }
            }
        }

        output.fileHandleForReading.readabilityHandler = nil
        if self.process === process { self.process = nil }
        return true
    }

    // MARK: - Разбор событий

    /// `ADD <udid> <network|usb>` или `REMOVE <udid>`.
    private func handle(_ line: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, parts[0] == "ADD" || parts[0] == "REMOVE" else { return }
        let udid = parts[1]
        // Пока телефон не выбран, интересно любое событие: как раз по нему он и найдётся.
        if let selected = monitor?.selectedDevice?.udid ?? Prefs.selectedUDID,
           selected.caseInsensitiveCompare(udid) != .orderedSame {
            return
        }
        Self.log.info("событие \(parts[0], privacy: .public) \(udid, privacy: .public) → опрос")
        poke()
    }

    /// Один опрос на пачку событий.
    private func poke() {
        guard pokeTask == nil else { return }
        pokeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard let self, !Task.isCancelled else { return }
            self.pokeTask = nil
            await self.monitor?.refresh(rediscover: true)
        }
    }
}

/// Склеивает куски вывода помощника в целые строки: `availableData` приходит
/// произвольными порциями и может разрезать строку пополам.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let index = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<index]
            pending = pending[pending.index(after: index)...]
            let text = String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(text) }
        }
        return lines
    }
}

/// `terminationHandler` может сработать после ошибки запуска — продолжение
/// возобновляем ровно один раз.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

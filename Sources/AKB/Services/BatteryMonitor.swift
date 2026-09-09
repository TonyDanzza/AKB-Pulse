import AppKit
import Foundation
import Observation
import OSLog

/// Состояние приложения: что показывать в строке меню и в popover.
@MainActor
@Observable
final class BatteryMonitor {

    enum Phase: Equatable {
        case idle
        case loading
        case ready(BatteryStatus)
        /// Связь потеряна, но последние показания ещё свежие: телефон спит (план §16.1).
        case stale(BatteryStatus)
        case failed(ProviderError)
    }

    // MARK: - Наблюдаемое состояние

    private(set) var phase: Phase = .idle
    private(set) var devices: [PhoneDevice] = []
    private(set) var selectedDevice: PhoneDevice?
    private(set) var lastKnownStatus: BatteryStatus?
    private(set) var isRefreshing = false

    // MARK: - Настройки, влияющие на отображение

    var showPercent: Bool { Prefs.showPercent }
    var threshold: Int { Prefs.lowThreshold }

    /// Заряд ниже порога и телефон не заряжается — красное состояние в строке меню.
    /// Уснувший телефон тоже считается: цифра приглушается, но красный остаётся.
    var isLow: Bool {
        guard let status = phase.status else { return false }
        return status.percent < threshold && !status.isCharging
    }

    // MARK: - Внутреннее

    static let log = Logger(subsystem: "ru.tonydanzza.akb", category: "monitor")

    private let provider: BatteryProvider
    private var policy: AlertPolicy
    private var timerTask: Task<Void, Never>?
    /// iPhone по Wi-Fi отвечает не каждый раз (радио засыпает). Одна осечка
    /// не должна стирать показания — уходим в ошибку только после трёх подряд.
    private var consecutiveFailures = 0
    static let failuresBeforeError = 3
    /// Последний опрос не попал в окно телефона — следующий делаем быстрее (план §17).
    private var lastPollFailed = false
    /// Пауза после неудачного опроса: телефон отвечает волнами, ждать полный
    /// интервал (до 5 минут) незачем.
    static let fastRetryDelay = 60
    private var observers: [NSObjectProtocol] = []
    /// Экран Mac спит или сессия заблокирована — опрос стоит (план §16.6).
    private var isPaused = false

    /// Сколько живут последние показания. Позже телефон считается недоступным (план §16.1).
    static let defaultStaleLimit: TimeInterval = 12 * 60 * 60
    /// До этого возраста показания считаются актуальными; дальше — «Нет связи» (план §16.5).
    static let defaultNoLinkAfter: TimeInterval = 15 * 60
    private let staleLimit: TimeInterval
    private let noLinkAfter: TimeInterval
    private let now: @MainActor () -> Date

    init(provider: BatteryProvider? = nil,
         staleLimit: TimeInterval = BatteryMonitor.defaultStaleLimit,
         noLinkAfter: TimeInterval = BatteryMonitor.defaultNoLinkAfter,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.staleLimit = staleLimit
        self.noLinkAfter = noLinkAfter
        self.now = now
        if let provider {
            self.provider = provider
        } else if let fake = FakeMode.percent {
            self.provider = FakeProvider(percent: fake,
                                         isCharging: FakeMode.isCharging,
                                         staleAfter: FakeMode.staleAfter)
        } else {
            self.provider = IMobileDeviceProvider()
        }
        self.policy = AlertPolicy(threshold: Prefs.lowThreshold,
                                  repeatEveryTenPercent: Prefs.repeatEveryTen)
    }

    // MARK: - Жизненный цикл

    func start() {
        observeWake()
        scheduleTimer()
        Task { await refresh(rediscover: true) }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers = []
    }

    /// Энергия (план §16.6): пока экран спит или сессия заблокирована, опрашивать
    /// телефон незачем — никто не смотрит. При пробуждении сразу спрашиваем заряд.
    private func observeWake() {
        let center = NSWorkspace.shared.notificationCenter
        let wake: [NSNotification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        let sleep: [NSNotification.Name] = [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]
        for name in wake {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.resume()
                }
            })
        }
        for name in sleep {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            })
        }
    }

    private func pause() {
        guard !isPaused else { return }
        isPaused = true
        timerTask?.cancel()
        timerTask = nil
        Self.log.info("опрос приостановлен: экран спит или сессия заблокирована")
    }

    private func resume() {
        isPaused = false
        Self.log.info("опрос возобновлён")
        scheduleTimer()
        Task { await refresh(rediscover: true) }
    }

    /// Перезапускает таймер опроса (вызывается при смене интервала в настройках).
    /// Задержка считается на каждой итерации: после неудачи она короче (план §17),
    /// а интервал из настроек подхватывается без пересоздания таймера.
    func scheduleTimer() {
        timerTask?.cancel()
        guard !isPaused else { return }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let seconds = self?.currentPollDelay() else { return }
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.refresh(rediscover: false)
            }
        }
    }

    /// Задержка до следующего опроса с записью в лог, когда идёт быстрый повтор.
    private func currentPollDelay() -> Int {
        let seconds = Self.nextPollDelay(interval: Prefs.pollInterval, lastFailed: lastPollFailed)
        if lastPollFailed {
            Self.log.info("повтор через \(seconds, privacy: .public) с после неудачи")
        }
        return seconds
    }

    /// Чистое правило выбора паузы (план §17): обычный интервал после успеха,
    /// не больше минуты — после неудачной попытки связи.
    static func nextPollDelay(interval: Int, lastFailed: Bool) -> Int {
        let interval = max(10, interval)
        return lastFailed ? min(fastRetryDelay, interval) : interval
    }

    /// Применяет изменения настроек уведомлений/порога.
    func settingsChanged() {
        policy = AlertPolicy(threshold: Prefs.lowThreshold,
                             repeatEveryTenPercent: Prefs.repeatEveryTen)
        scheduleTimer()
        Task { await refresh(rediscover: false) }
    }

    func select(_ device: PhoneDevice) {
        selectedDevice = device
        Prefs.selectedUDID = device.udid
        policy.reset()
        Task { await refresh(rediscover: false) }
    }

    // MARK: - Опрос

    func refresh(rediscover: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if case .idle = phase { phase = .loading }

        do {
            // Пока телефон считается спящим, список устройств пуст — ищем заново каждый раз.
            if rediscover || devices.isEmpty || selectedDevice == nil || phase.isStale {
                let found = try await provider.listDevices()
                Self.log.info("найдено устройств: \(found.count, privacy: .public)")
                devices = found
                selectedDevice = Self.pick(from: found, preferredUDID: Prefs.selectedUDID)
            }
            guard let device = selectedDevice else {
                fail(with: .noDevice)
                return
            }
            let status = try await provider.battery(for: device)
            lastKnownStatus = status
            consecutiveFailures = 0
            lastPollFailed = false
            phase = .ready(status)
            evaluateAlert(status, device: device)
        } catch let error as ProviderError {
            Self.log.info("опрос не удался: \(String(describing: error), privacy: .public)")
            fail(with: error)
        } catch {
            Self.log.info("неожиданная ошибка: \(String(describing: error), privacy: .public)")
            fail(with: .parseFailure)
        }
    }

    /// Только обновление списка устройств (кнопка в настройках).
    func rediscoverDevices() async {
        do {
            let found = try await provider.listDevices()
            devices = found
            if selectedDevice == nil || !found.contains(where: { $0.udid == selectedDevice?.udid }) {
                selectedDevice = Self.pick(from: found, preferredUDID: Prefs.selectedUDID)
            }
        } catch let error as ProviderError {
            devices = []
            phase = .failed(error)
        } catch {
            devices = []
        }
    }

    /// Ошибка опроса. Пока показания свежие, короткие обрывы связи не стирают экран.
    private func fail(with error: ProviderError) {
        consecutiveFailures += 1
        // Быстрый повтор помогает только при обрыве связи; сломанный инструмент
        // или нечитаемый вывод от этого не починятся (план §17).
        switch error {
        case .noDevice, .deviceUnreachable, .timeout: lastPollFailed = true
        case .toolNotFound, .parseFailure: lastPollFailed = false
        }
        phase = Self.nextPhase(current: phase,
                               error: error,
                               lastKnown: lastKnownStatus,
                               now: now(),
                               noLinkAfter: noLinkAfter,
                               staleLimit: staleLimit,
                               failures: consecutiveFailures)
    }

    /// Чистое правило перехода после неудачного опроса (план §16.1) — вся логика stale здесь,
    /// чтобы её можно было проверить тестами без таймеров, уведомлений и настроек.
    ///
    /// - `.toolNotFound` / `.parseFailure` — это поломка, а не сон: сразу `.failed`.
    /// - Первые неудачи подряд, пока на экране свежие данные, ничего не меняют.
    /// - Показания моложе `noLinkAfter` (15 мин) остаются `.ready`: телефон просто
    ///   не ответил в эту волну, число всё ещё верное.
    /// - Старше — `.stale` («Нет связи · данные 14:32»), старше `staleLimit` — `.failed`.
    static func nextPhase(current: Phase,
                          error: ProviderError,
                          lastKnown: BatteryStatus?,
                          now: Date,
                          noLinkAfter: TimeInterval = BatteryMonitor.defaultNoLinkAfter,
                          staleLimit: TimeInterval,
                          failures: Int,
                          failuresBeforeError: Int = BatteryMonitor.failuresBeforeError) -> Phase {
        switch error {
        case .toolNotFound, .parseFailure:
            return .failed(error)
        case .noDevice, .deviceUnreachable, .timeout:
            break
        }
        if case .ready = current, failures < failuresBeforeError {
            return current
        }
        guard let lastKnown else { return .failed(error) }
        let age = now.timeIntervalSince(lastKnown.updatedAt)
        if age < noLinkAfter { return .ready(lastKnown) }
        if age < staleLimit { return .stale(lastKnown) }
        return .failed(error)
    }

    /// Выбор устройства: сохранённый UDID → семейство iPhone 17 → первый найденный (план §2).
    static func pick(from devices: [PhoneDevice], preferredUDID: String?) -> PhoneDevice? {
        if let preferredUDID, let saved = devices.first(where: { $0.udid == preferredUDID }) {
            return saved
        }
        return devices.first(where: { $0.isIPhone17Family }) ?? devices.first
    }

    private func evaluateAlert(_ status: BatteryStatus, device: PhoneDevice) {
        guard Prefs.notifyLowBattery else {
            policy.reset()
            return
        }
        if policy.threshold != Prefs.lowThreshold || policy.repeatEveryTenPercent != Prefs.repeatEveryTen {
            policy = AlertPolicy(threshold: Prefs.lowThreshold,
                                 repeatEveryTenPercent: Prefs.repeatEveryTen)
        }
        if policy.evaluate(status) {
            NotificationService.shared.postLowBattery(deviceName: device.name, percent: status.percent)
        }
    }
}

extension BatteryMonitor.Phase {
    /// Пустое состояние занимает больше места, чем обычный экран с цифрой.
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    /// Показания, которые сейчас на экране: свежие или последние известные.
    var status: BatteryStatus? {
        switch self {
        case .ready(let status), .stale(let status): status
        case .idle, .loading, .failed: nil
        }
    }
}

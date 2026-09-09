import AppKit
import Foundation
import Observation

/// Состояние приложения: что показывать в строке меню и в popover.
@MainActor
@Observable
final class BatteryMonitor {

    enum Phase: Equatable {
        case idle
        case loading
        case ready(BatteryStatus)
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
    var isLow: Bool {
        guard case .ready(let status) = phase else { return false }
        return status.percent < threshold && !status.isCharging
    }

    // MARK: - Внутреннее

    private let provider: BatteryProvider
    private var policy: AlertPolicy
    private var timerTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init(provider: BatteryProvider? = nil) {
        if let provider {
            self.provider = provider
        } else if let fake = FakeMode.percent {
            self.provider = FakeProvider(percent: fake, isCharging: FakeMode.isCharging)
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
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh(rediscover: true) }
            }
        }
    }

    /// Перезапускает таймер опроса (вызывается при смене интервала в настройках).
    func scheduleTimer() {
        timerTask?.cancel()
        let seconds = max(10, Prefs.pollInterval)
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.refresh(rediscover: false)
            }
        }
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
            if rediscover || devices.isEmpty || selectedDevice == nil {
                let found = try await provider.listDevices()
                devices = found
                selectedDevice = Self.pick(from: found, preferredUDID: Prefs.selectedUDID)
            }
            guard let device = selectedDevice else {
                phase = .failed(.noDevice)
                return
            }
            let status = try await provider.battery(for: device)
            lastKnownStatus = status
            phase = .ready(status)
            evaluateAlert(status, device: device)
        } catch let error as ProviderError {
            phase = .failed(error)
        } catch {
            phase = .failed(.parseFailure)
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

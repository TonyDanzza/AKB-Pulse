import Foundation
import Testing
@testable import AKB

private let phone = PhoneDevice(udid: "MON-PHONE", name: "iPhone (Тони)", productType: "iPhone18,3", transport: .wifi)
private let older = PhoneDevice(udid: "MON-OLDER", name: "Старый", productType: "iPhone15,4", transport: .usb)

private struct Boom: Error {}

/// Источник по сценарию: очередь ответов, последний повторяется бесконечно.
private actor ScriptedProvider: BatteryProvider {
    private var deviceQueue: [Result<[PhoneDevice], Error>]
    private var batteryQueue: [Result<BatteryStatus, Error>]
    private var healthQueue: [Result<BatteryHealth, Error>]
    private(set) var listCalls = 0
    private(set) var batteryCalls = 0
    private(set) var healthCalls = 0
    private var delay: Duration = .zero

    init(devices: [Result<[PhoneDevice], Error>] = [.success([phone])],
         batteries: [Result<BatteryStatus, Error>] = [],
         healths: [Result<BatteryHealth, Error>] = [.failure(ProviderError.deviceUnreachable("MON-PHONE"))]) {
        deviceQueue = devices
        batteryQueue = batteries
        healthQueue = healths
    }

    func devices(_ queue: [Result<[PhoneDevice], Error>]) { deviceQueue = queue }
    func batteries(_ queue: [Result<BatteryStatus, Error>]) { batteryQueue = queue }
    func healths(_ queue: [Result<BatteryHealth, Error>]) { healthQueue = queue }
    func setDelay(_ value: Duration) { delay = value }

    func listDevices() async throws -> [PhoneDevice] {
        listCalls += 1
        return try Self.take(&deviceQueue)
    }

    func battery(for device: PhoneDevice) async throws -> BatteryStatus {
        batteryCalls += 1
        if delay > .zero { try? await Task.sleep(for: delay) }
        return try Self.take(&batteryQueue)
    }

    func health(for device: PhoneDevice) async throws -> BatteryHealth {
        healthCalls += 1
        return try Self.take(&healthQueue)
    }

    private static func take<T>(_ queue: inout [Result<T, Error>]) throws -> T {
        guard let first = queue.first else { throw Boom() }   // сценарий кончился
        if queue.count > 1 { queue.removeFirst() }
        return try first.get()
    }
}

@MainActor
private final class TestClock {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@MainActor
private func prepareDefaults() {
    let defaults = UserDefaults.standard
    defaults.set(false, forKey: Prefs.Key.notifyLowBattery)   // без UNUserNotificationCenter в тестах
    defaults.set(30, forKey: Prefs.Key.lowThreshold)
    defaults.set(true, forKey: Prefs.Key.repeatEveryTen)
    defaults.set(60, forKey: Prefs.Key.pollInterval)
    defaults.removeObject(forKey: Prefs.Key.selectedUDID)
    // Здоровье живёт в UserDefaults между запусками — тестам нужен чистый лист.
    defaults.removeObject(forKey: Prefs.Key.batteryHealth)
    defaults.removeObject(forKey: Prefs.Key.healthAttemptedAt)
}

@MainActor
@Suite("Монитор заряда", .serialized)
struct BatteryMonitorTests {

    private func status(_ percent: Int, at clock: TestClock, charging: Bool = false, source: BatteryStatus.Source = .usbmuxd) -> BatteryStatus {
        BatteryStatus(percent: percent, isCharging: charging, externalConnected: charging,
                      updatedAt: clock.date, source: source)
    }

    private func make(_ provider: ScriptedProvider, clock: TestClock) -> BatteryMonitor {
        prepareDefaults()
        return BatteryMonitor(provider: provider, now: { clock.date })
    }

    @Test("Первый опрос: устройство найдено, показания на экране")
    func firstPoll() async {
        let clock = TestClock()
        let reading = status(74, at: clock)
        let provider = ScriptedProvider(batteries: [.success(reading)])
        let monitor = make(provider, clock: clock)
        #expect(monitor.phase == .idle)

        await monitor.refresh(rediscover: true)

        #expect(monitor.phase == .ready(reading))
        #expect(monitor.devices == [phone])
        #expect(monitor.selectedDevice == phone)
        #expect(monitor.lastKnownStatus == reading)
        #expect(monitor.isRefreshing == false)
        #expect(await provider.listCalls == 1)
        #expect(await provider.batteryCalls == 1)
    }

    @Test("Устройств нет вовсе — ошибка noDevice, заряд не спрашивается")
    func noDevices() async {
        let clock = TestClock()
        let provider = ScriptedProvider(devices: [.success([])])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        #expect(monitor.phase == .failed(.noDevice))
        #expect(monitor.selectedDevice == nil)
        #expect(await provider.batteryCalls == 0)
    }

    @Test("Поиск устройств бросил ошибку — она и показывается")
    func listThrows() async {
        let clock = TestClock()
        let provider = ScriptedProvider(devices: [.failure(ProviderError.toolNotFound)])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        #expect(monitor.phase == .failed(.toolNotFound))
    }

    @Test("Чужая ошибка превращается в parseFailure")
    func foreignError() async {
        let clock = TestClock()
        let provider = ScriptedProvider(batteries: [.failure(Boom())])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        #expect(monitor.phase == .failed(.parseFailure))
    }

    @Test("Две осечки подряд не стирают показания")
    func twoMissesKeepReading() async {
        let clock = TestClock()
        let reading = status(74, at: clock)
        let provider = ScriptedProvider(batteries: [.success(reading), .failure(ProviderError.deviceUnreachable(phone.udid))])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        clock.advance(60)
        await monitor.refresh(rediscover: false)
        clock.advance(60)
        await monitor.refresh(rediscover: false)
        #expect(monitor.phase == .ready(reading))
        #expect(monitor.lastKnownStatus == reading)
    }

    @Test("Третья осечка со свежими данными — всё ещё ready")
    func thirdMissFresh() async {
        let clock = TestClock()
        let reading = status(74, at: clock)
        let provider = ScriptedProvider(batteries: [.success(reading), .failure(ProviderError.timeout)])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        for _ in 0..<3 {
            clock.advance(60)
            await monitor.refresh(rediscover: false)
        }
        #expect(monitor.phase == .ready(reading))
    }

    @Test("Третья осечка со старыми данными — stale, через 12 часов — failed")
    func thirdMissOld() async {
        let clock = TestClock()
        let reading = status(74, at: clock)
        let provider = ScriptedProvider(batteries: [.success(reading), .failure(ProviderError.deviceUnreachable(phone.udid))])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        clock.advance(20 * 60)
        for _ in 0..<3 { await monitor.refresh(rediscover: false) }
        #expect(monitor.phase == .stale(reading))
        #expect(monitor.phase.status?.percent == 74)

        clock.advance(13 * 60 * 60)
        await monitor.refresh(rediscover: false)
        #expect(monitor.phase == .failed(.deviceUnreachable(phone.udid)))
        // Последние показания в памяти остаются — пригодятся, если телефон вернётся.
        #expect(monitor.lastKnownStatus == reading)
    }

    @Test("Успех сбрасывает счётчик осечек")
    func successResetsCounter() async {
        let clock = TestClock()
        let reading = status(74, at: clock)
        let miss = Result<BatteryStatus, Error>.failure(ProviderError.deviceUnreachable(phone.udid))
        let provider = ScriptedProvider(batteries: [.success(reading), miss, miss, .success(reading), miss, miss, miss])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        clock.advance(20 * 60)   // данные старые: третья осечка подряд дала бы stale
        await monitor.refresh(rediscover: false)   // miss 1
        await monitor.refresh(rediscover: false)   // miss 2
        await monitor.refresh(rediscover: false)   // success: счётчик в ноль
        await monitor.refresh(rediscover: false)   // miss 1
        await monitor.refresh(rediscover: false)   // miss 2
        #expect(monitor.phase == .ready(reading))
        await monitor.refresh(rediscover: false)   // miss 3
        #expect(monitor.phase == .stale(reading))
    }

    @Test("После stale успешный опрос возвращает ready и заново ищет устройство")
    func staleThenSuccess() async {
        let clock = TestClock()
        let old = status(74, at: clock)
        let provider = ScriptedProvider(batteries: [.success(old), .failure(ProviderError.timeout)])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        clock.advance(20 * 60)
        for _ in 0..<3 { await monitor.refresh(rediscover: false) }
        #expect(monitor.phase.isStale)
        let listCallsBefore = await provider.listCalls

        let fresh = status(70, at: clock)
        await provider.batteries([.success(fresh)])
        await monitor.refresh(rediscover: false)
        #expect(monitor.phase == .ready(fresh))
        #expect(await provider.listCalls == listCallsBefore + 1)
    }

    @Test("Пока устройство известно, повторный опрос не ищет его заново")
    func noRediscoverWhenKnown() async {
        let clock = TestClock()
        let provider = ScriptedProvider(batteries: [.success(status(74, at: clock))])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        await monitor.refresh(rediscover: false)
        await monitor.refresh(rediscover: false)
        #expect(await provider.listCalls == 1)
        #expect(await provider.batteryCalls == 3)
    }

    @Test("Сломанный инструмент — сразу failed, даже со свежими данными")
    func toolMissingIsImmediate() async {
        let clock = TestClock()
        let provider = ScriptedProvider(batteries: [.success(status(74, at: clock)), .failure(ProviderError.toolNotFound)])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        await monitor.refresh(rediscover: false)
        #expect(monitor.phase == .failed(.toolNotFound))
    }

    @Test("Выбор телефона сохраняется и переживает повторный поиск")
    func selectionPersists() async {
        let clock = TestClock()
        let provider = ScriptedProvider(devices: [.success([older, phone])], batteries: [.success(status(50, at: clock))])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        #expect(monitor.selectedDevice == phone)   // iPhone 17 предпочтительнее

        monitor.select(older)
        #expect(monitor.selectedDevice == older)
        #expect(Prefs.selectedUDID == older.udid)

        await monitor.refresh(rediscover: true)
        #expect(monitor.selectedDevice == older)
        UserDefaults.standard.removeObject(forKey: Prefs.Key.selectedUDID)
    }

    @Test("isLow: ниже порога и не на зарядке; спящий телефон тоже считается")
    func isLow() async {
        let clock = TestClock()
        let provider = ScriptedProvider(batteries: [.success(status(25, at: clock))])
        let monitor = make(provider, clock: clock)
        #expect(monitor.isLow == false)   // данных ещё нет
        await monitor.refresh(rediscover: true)
        #expect(monitor.threshold == 30)
        #expect(monitor.isLow)

        await provider.batteries([.success(status(25, at: clock, charging: true))])
        await monitor.refresh(rediscover: false)
        #expect(monitor.isLow == false)

        await provider.batteries([.success(status(35, at: clock))])
        await monitor.refresh(rediscover: false)
        #expect(monitor.isLow == false)

        // Уснул с 25%: stale, но по-прежнему «мало».
        await provider.batteries([.success(status(25, at: clock)), .failure(ProviderError.timeout)])
        await monitor.refresh(rediscover: false)
        clock.advance(20 * 60)
        for _ in 0..<3 { await monitor.refresh(rediscover: false) }
        #expect(monitor.phase.isStale)
        #expect(monitor.isLow)
    }

    @Test("Два опроса одновременно — источник спрашивается один раз")
    func overlappingRefresh() async {
        let clock = TestClock()
        let provider = ScriptedProvider(batteries: [.success(status(74, at: clock))])
        await provider.setDelay(.milliseconds(300))
        let monitor = make(provider, clock: clock)
        async let first: Void = monitor.refresh(rediscover: true)
        async let second: Void = monitor.refresh(rediscover: true)
        _ = await (first, second)
        #expect(await provider.batteryCalls == 1)
        #expect(monitor.phase.status?.percent == 74)
    }

    @Test("Обновление списка устройств оставляет выбор, если телефон на месте")
    func rediscoverKeepsSelection() async {
        let clock = TestClock()
        let provider = ScriptedProvider(devices: [.success([phone])], batteries: [.success(status(74, at: clock))])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        await provider.devices([.success([older, phone])])
        await monitor.rediscoverDevices()
        #expect(monitor.devices == [older, phone])
        #expect(monitor.selectedDevice == phone)
    }

    @Test("Обновление списка: телефон пропал — выбирается другой")
    func rediscoverPicksAnother() async {
        let clock = TestClock()
        let provider = ScriptedProvider(devices: [.success([phone])], batteries: [.success(status(74, at: clock))])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        await provider.devices([.success([older])])
        await monitor.rediscoverDevices()
        #expect(monitor.selectedDevice == older)
    }

    /// Кандидат на баг (план тестов, №1): кнопка «Обновить список» при спящем
    /// телефоне не должна стирать свежие показания с экрана (план §16.1 —
    /// короткие обрывы связи экран не трогают). Если тест падает — это
    /// повод разобраться, а не молча переписать ожидание.
    @Test("Обновление списка не удалось — свежие показания остаются на экране")
    func rediscoverFailureKeepsFreshReading() async {
        let clock = TestClock()
        let reading = status(74, at: clock)
        let provider = ScriptedProvider(devices: [.success([phone])], batteries: [.success(reading)])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        await provider.devices([.failure(ProviderError.noDevice)])
        clock.advance(60)
        await monitor.rediscoverDevices()
        #expect(monitor.phase.status == reading)
        #expect(monitor.lastKnownStatus == reading)
    }

    @Test("Ошибка после failed без данных остаётся failed с новой ошибкой")
    func failedStaysFailed() async {
        let clock = TestClock()
        let provider = ScriptedProvider(batteries: [.failure(ProviderError.timeout), .failure(ProviderError.deviceUnreachable(phone.udid))])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        #expect(monitor.phase == .failed(.timeout))
        await monitor.refresh(rediscover: false)
        #expect(monitor.phase == .failed(.deviceUnreachable(phone.udid)))
    }

    @Test("Изменение настроек не роняет монитор и не трогает показания")
    func settingsChangedKeepsReading() async {
        let clock = TestClock()
        let reading = status(74, at: clock)
        let provider = ScriptedProvider(batteries: [.success(reading)])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        monitor.settingsChanged()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(monitor.phase == .ready(reading))
        monitor.stop()
    }
}

@MainActor
@Suite("Возраст показаний: границы")
struct BatteryPhaseBoundaryTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func phase(age: TimeInterval, failures: Int = 3, current: BatteryMonitor.Phase? = nil) -> BatteryMonitor.Phase {
        let last = BatteryStatus(percent: 50, updatedAt: now.addingTimeInterval(-age))
        return BatteryMonitor.nextPhase(current: current ?? .ready(last),
                                        error: .timeout,
                                        lastKnown: last,
                                        now: now,
                                        noLinkAfter: 15 * 60,
                                        staleLimit: 12 * 60 * 60,
                                        failures: failures)
    }

    @Test("Ровно 15 минут — уже stale, секундой раньше — ready")
    func noLinkBoundary() {
        #expect(phase(age: 15 * 60 - 1).isStale == false)
        #expect(phase(age: 15 * 60).isStale)
    }

    @Test("Ровно 12 часов — уже failed")
    func staleLimitBoundary() {
        #expect(phase(age: 12 * 60 * 60 - 1).isStale)
        #expect(phase(age: 12 * 60 * 60).isFailed)
    }

    @Test("Из stale первая же осечка пересчитывает возраст, не ждёт трёх")
    func fromStaleNoGracePeriod() {
        let last = BatteryStatus(percent: 50, updatedAt: now.addingTimeInterval(-13 * 60 * 60))
        let next = BatteryMonitor.nextPhase(current: .stale(last), error: .timeout, lastKnown: last,
                                            now: now, staleLimit: 12 * 60 * 60, failures: 1)
        #expect(next.isFailed)
    }

    @Test("Из failed со свежими данными — обратно в ready")
    func fromFailedWithFreshData() {
        let last = BatteryStatus(percent: 50, updatedAt: now.addingTimeInterval(-60))
        let next = BatteryMonitor.nextPhase(current: .failed(.noDevice), error: .timeout, lastKnown: last,
                                            now: now, staleLimit: 12 * 60 * 60, failures: 1)
        #expect(next == .ready(last))
    }

    @Test("Порог осечек 0 — льготы нет")
    func zeroGrace() {
        let last = BatteryStatus(percent: 50, updatedAt: now.addingTimeInterval(-20 * 60))
        let next = BatteryMonitor.nextPhase(current: .ready(last), error: .timeout, lastKnown: last,
                                            now: now, staleLimit: 12 * 60 * 60, failures: 0, failuresBeforeError: 0)
        #expect(next.isStale)
    }

    @Test("Показания из будущего (часы сбились) считаются свежими")
    func futureTimestamp() {
        #expect(phase(age: -3600).status?.percent == 50)
        #expect(phase(age: -3600).isStale == false)
    }
}

@MainActor
@Suite("Здоровье батареи в мониторе", .serialized)
struct MonitorHealthTests {

    private let sample = BatteryHealth(cycleCount: 243, designCapacity: 3654,
                                       nominalCapacity: 3609, fullChargeCapacity: 3632,
                                       voltage: 4197, amperage: -58, timeRemaining: 1472)

    private func make(_ provider: ScriptedProvider, clock: TestClock) -> BatteryMonitor {
        prepareDefaults()
        return BatteryMonitor(provider: provider, now: { clock.date })
    }

    private func reading(_ clock: TestClock) -> BatteryStatus {
        BatteryStatus(percent: 74, updatedAt: clock.date)
    }

    @Test("После удачного заряда здоровье спрашивается ровно один раз")
    func askedOnce() async {
        let clock = TestClock()
        let provider = ScriptedProvider(batteries: [.success(reading(clock))],
                                        healths: [.success(sample)])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        #expect(await provider.healthCalls == 1)
        #expect(monitor.health?.cycleCount == 243)
        #expect(monitor.health?.maximumCapacityPercent == 99)
        // Время чтения — по часам Mac, а не то, что положил источник.
        #expect(monitor.health?.updatedAt == clock.date)
        #expect(Prefs.health(udid: phone.udid)?.cycleCount == 243)
        prepareDefaults()
    }

    @Test("Через минуту здоровье заново не спрашивается")
    func notAskedAgainSoon() async {
        let clock = TestClock()
        let provider = ScriptedProvider(batteries: [.success(reading(clock))],
                                        healths: [.success(sample)])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        clock.advance(60)
        await monitor.refresh(rediscover: false)
        #expect(await provider.healthCalls == 1)
        prepareDefaults()
    }

    @Test("Через два часа — спрашивается снова")
    func askedAgainAfterHours() async {
        let clock = TestClock()
        let provider = ScriptedProvider(batteries: [.success(reading(clock))],
                                        healths: [.success(sample)])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        clock.advance(2 * 60 * 60)
        await monitor.refresh(rediscover: false)
        #expect(await provider.healthCalls == 2)
        prepareDefaults()
    }

    @Test("Неудача здоровья не трогает ни фазу, ни экран заряда")
    func failureIsQuiet() async {
        let clock = TestClock()
        let status = reading(clock)
        let provider = ScriptedProvider(batteries: [.success(status)],
                                        healths: [.failure(ProviderError.deviceUnreachable(phone.udid))])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        #expect(monitor.phase == .ready(status))
        #expect(monitor.health == nil)
        #expect(await provider.healthCalls == 1)
        // Попытка записана: следующие десять минут телефон не тревожим.
        clock.advance(60)
        await monitor.refresh(rediscover: false)
        #expect(await provider.healthCalls == 1)
        prepareDefaults()
    }

    @Test("Кнопка «Обновить» спрашивает вопреки правилу раз-в-час")
    func forcedRefresh() async {
        let clock = TestClock()
        let provider = ScriptedProvider(batteries: [.success(reading(clock))],
                                        healths: [.success(sample)])
        let monitor = make(provider, clock: clock)
        await monitor.refresh(rediscover: true)
        await monitor.refreshHealth()          // правило говорит «рано»
        #expect(await provider.healthCalls == 1)
        await monitor.refreshHealth(force: true)
        #expect(await provider.healthCalls == 2)
        #expect(monitor.isRefreshingHealth == false)
        prepareDefaults()
    }

    @Test("Смена телефона подменяет здоровье на сохранённое для него")
    func selectSwapsHealth() async {
        let clock = TestClock()
        let provider = ScriptedProvider(devices: [.success([older, phone])],
                                        batteries: [.success(reading(clock))],
                                        healths: [.success(sample)])
        let monitor = make(provider, clock: clock)
        var forOlder = sample
        forOlder.cycleCount = 900
        Prefs.setHealth(forOlder, udid: older.udid)

        await monitor.refresh(rediscover: true)
        #expect(monitor.selectedDevice == phone)
        #expect(monitor.health?.cycleCount == 243)

        monitor.select(older)
        #expect(monitor.health?.cycleCount == 900)
        prepareDefaults()
        UserDefaults.standard.removeObject(forKey: Prefs.Key.selectedUDID)
    }

    @Test("Здоровье, сохранённое в прошлый запуск, видно сразу при создании монитора")
    func restoredFromPrefs() async {
        prepareDefaults()
        Prefs.selectedUDID = phone.udid
        Prefs.setHealth(sample, udid: phone.udid)
        let monitor = BatteryMonitor(provider: ScriptedProvider())
        #expect(monitor.health?.cycleCount == 243)
        prepareDefaults()
        UserDefaults.standard.removeObject(forKey: Prefs.Key.selectedUDID)
    }
}

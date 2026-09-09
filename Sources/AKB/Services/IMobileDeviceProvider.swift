import Foundation

/// Реализация `BatteryProvider` поверх утилит libimobiledevice (`idevice_id`, `ideviceinfo`)
/// и собственного помощника `akb-direct` для спящего телефона (план §16).
/// Все вызовы `Process` идут через `ProcessRunner` — вне главного потока, с таймаутом 10 с.
struct IMobileDeviceProvider: BatteryProvider {

    var timeout: TimeInterval = 10
    /// Окно повторов прямого чтения по IP. Телефон отвечает волнами (план §16.1).
    var retry = RetryWindow()
    var resolver = DeviceAddressResolver()
    /// Настойчивый первый поиск телефона в Bonjour: 15 с шагом 3 с (см. listDevices).
    var discovery = RetryWindow(window: 15, interval: 3)

    private func tool(_ name: String) throws -> URL {
        guard let url = ToolLocator.locate(name) else { throw ProviderError.toolNotFound }
        return url
    }

    // MARK: - Устройства

    func listDevices() async throws -> [PhoneDevice] {
        if FakeMode.forceNoDevice { throw ProviderError.noDevice }

        let ideviceID = try tool("idevice_id")

        // Wi-Fi имеет приоритет: если UDID виден и по кабелю, и по сети, показываем Wi-Fi.
        var transports: [String: PhoneDevice.Transport] = [:]
        var order: [String] = []

        func scan() async {
            for (flag, transport) in [("-n", PhoneDevice.Transport.wifi), ("-l", .usb)] {
                let result = try? await ProcessRunner.run(ideviceID, arguments: [flag], timeout: timeout)
                guard let result else { continue }
                for udid in IMobileDeviceOutputParser.udidList(result.stdout) {
                    if transports[udid] == nil {
                        transports[udid] = transport
                        order.append(udid)
                    }
                }
            }
        }

        await scan()

        // Первое знакомство: про телефон ничего не известно, а Bonjour-запись он
        // публикует такими же короткими волнами, как держит открытым lockdownd, —
        // за один опрос в неё почти не попасть. Поэтому, пока кэша нет, ищем
        // настойчивее. Как только телефон найден хоть раз, эта ветка не работает.
        if order.isEmpty, cachedDevice() == nil {
            try? await discovery.run { _ in
                await scan()
                if order.isEmpty { throw ProviderError.noDevice }
            }
        }

        // Спящий телефон исчезает из usbmuxd целиком. Тогда берём его из памяти:
        // имя и модель сохранены с прошлого раза, адрес найдёт DeviceAddressResolver.
        guard !order.isEmpty else {
            guard let cached = cachedDevice() else { throw ProviderError.noDevice }
            AKBLog.info(.provider, "usbmuxd пуст, устройство из кэша: \(cached.name)")
            return [cached]
        }

        var devices: [PhoneDevice] = []
        for udid in order {
            let transport = transports[udid] ?? .usb
            let name = (try? await value(forKey: "DeviceName", udid: udid, transport: transport))
                ?? Prefs.deviceNames[udid] ?? udid
            let productType = (try? await value(forKey: "ProductType", udid: udid, transport: transport))
                ?? Prefs.deviceProductTypes[udid] ?? ""
            let device = PhoneDevice(udid: udid, name: name, productType: productType, transport: transport)
            Prefs.remember(device)
            devices.append(device)
        }
        return devices
    }

    /// Телефон, про который уже известно имя и куда стучаться.
    private func cachedDevice() -> PhoneDevice? {
        if let udid = Prefs.selectedUDID, let cached = Prefs.cachedDevice(udid: udid) { return cached }
        if let udid = Prefs.deviceNames.keys.sorted().first { return Prefs.cachedDevice(udid: udid) }
        return nil
    }

    private func value(forKey key: String, udid: String, transport: PhoneDevice.Transport) async throws -> String {
        let ideviceinfo = try tool("ideviceinfo")
        var args: [String] = []
        if transport == .wifi { args.append("-n") }
        args += ["-u", udid, "-k", key]
        let result = try await ProcessRunner.run(ideviceinfo, arguments: args, timeout: timeout)
        guard result.status == 0,
              let parsed = IMobileDeviceOutputParser.singleValue(result.stdout)
        else { throw ProviderError.deviceUnreachable(udid) }
        return parsed
    }

    // MARK: - Заряд

    /// Два пути. Быстрый — обычный `ideviceinfo`, работает, пока телефон бодрствует
    /// и виден usbmuxd. Если не вышло — прямое чтение по IP через `akb-direct`
    /// в окне повторов: спящий телефон отвечает волнами (план §16.1, §16.4).
    func battery(for device: PhoneDevice) async throws -> BatteryStatus {
        let started = Date()
        if let status = try? await batteryViaUSBMux(device) {
            await resolver.warmCache(udid: device.udid)
            AKBLog.info(.provider, """
                заряд \(status.percent)% путём usbmuxd \
                за \(String(format: "%.1f", Date().timeIntervalSince(started))) с
                """)
            return status
        }
        return try await batteryDirect(device, started: started)
    }

    private func batteryViaUSBMux(_ device: PhoneDevice) async throws -> BatteryStatus {
        let ideviceinfo = try tool("ideviceinfo")
        var args: [String] = []
        if device.transport == .wifi { args.append("-n") }
        args += ["-u", device.udid, "-q", "com.apple.mobile.battery"]

        let result = try await ProcessRunner.run(ideviceinfo, arguments: args, timeout: timeout)
        guard result.status == 0 else { throw ProviderError.deviceUnreachable(device.udid) }
        guard let status = IMobileDeviceOutputParser.battery(result.stdout) else {
            throw ProviderError.parseFailure
        }
        return status
    }

    /// Прямое чтение по IP. Адрес ищет `DeviceAddressResolver`; если за всё окно
    /// телефон так и не ответил, кэш адреса сбрасывается — вдруг он сменил IP.
    private func batteryDirect(_ device: PhoneDevice, started: Date) async throws -> BatteryStatus {
        guard let resolved = await resolver.resolve(udid: device.udid) else {
            throw ProviderError.deviceUnreachable(device.udid)
        }
        let akbDirect = try tool("akb-direct")
        do {
            let status = try await retry.run { attempt in
                let result = try await ProcessRunner.run(
                    akbDirect,
                    arguments: ["battery", resolved.ip, device.udid],
                    timeout: min(timeout, retry.interval + 5)
                )
                guard result.status == 0 else {
                    throw ProviderError.deviceUnreachable(device.udid)
                }
                guard let status = IMobileDeviceOutputParser.battery(result.stdout) else {
                    throw ProviderError.parseFailure
                }
                AKBLog.info(.provider, """
                    заряд \(status.percent)% путём direct \
                    (\(resolved.ip), адрес: \(resolved.source.rawValue), \
                    попытка \(attempt + 1)) \
                    за \(String(format: "%.1f", Date().timeIntervalSince(started))) с
                    """)
                return status
            }
            return status
        } catch {
            await resolver.invalidate(udid: device.udid)
            AKBLog.info(.provider, """
                direct не ответил за \(String(format: "%.0f", Date().timeIntervalSince(started))) с \
                (\(resolved.ip)), адрес забыт
                """)
            if let providerError = error as? ProviderError { throw providerError }
            throw ProviderError.deviceUnreachable(device.udid)
        }
    }
}

/// Подставной источник для отладки и снимков экрана (`AKB_FAKE_PERCENT`).
struct FakeProvider: BatteryProvider {

    var percent: Int
    var isCharging: Bool
    /// Сколько секунд телефон отвечает, прежде чем «уснуть» (`AKB_FAKE_STALE_AFTER`).
    var staleAfter: TimeInterval?
    /// Точка отсчёта сна. Задаётся при создании провайдера, то есть при запуске приложения.
    var startedAt: Date = Date()

    private var isAsleep: Bool {
        guard let staleAfter else { return false }
        return Date().timeIntervalSince(startedAt) >= staleAfter
    }

    func listDevices() async throws -> [PhoneDevice] {
        // Уснувший телефон пропадает из Bonjour ровно так же, как настоящий.
        if isAsleep { throw ProviderError.deviceUnreachable("FAKE-0000-0000") }
        return [PhoneDevice(udid: "FAKE-0000-0000",
                            name: "iPhone (Тони)",
                            productType: "iPhone18,3",
                            transport: .wifi)]
    }

    func battery(for device: PhoneDevice) async throws -> BatteryStatus {
        if isAsleep { throw ProviderError.deviceUnreachable(device.udid) }
        return BatteryStatus(percent: percent,
                             isCharging: isCharging,
                             externalConnected: isCharging,
                             fullyCharged: percent >= 100,
                             updatedAt: Date())
    }
}

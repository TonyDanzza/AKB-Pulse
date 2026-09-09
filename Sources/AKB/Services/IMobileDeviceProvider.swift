import Foundation

/// Реализация `BatteryProvider` поверх утилит libimobiledevice (`idevice_id`, `ideviceinfo`).
/// Все вызовы `Process` идут через `ProcessRunner` — вне главного потока, с таймаутом 10 с.
struct IMobileDeviceProvider: BatteryProvider {

    var timeout: TimeInterval = 10

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

        guard !order.isEmpty else { throw ProviderError.noDevice }

        var devices: [PhoneDevice] = []
        for udid in order {
            let transport = transports[udid] ?? .usb
            let name = (try? await value(forKey: "DeviceName", udid: udid, transport: transport)) ?? udid
            let productType = (try? await value(forKey: "ProductType", udid: udid, transport: transport)) ?? ""
            devices.append(PhoneDevice(udid: udid, name: name, productType: productType, transport: transport))
        }
        return devices
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

    func battery(for device: PhoneDevice) async throws -> BatteryStatus {
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
}

/// Подставной источник для отладки и снимков экрана (`AKB_FAKE_PERCENT`).
struct FakeProvider: BatteryProvider {

    var percent: Int
    var isCharging: Bool

    func listDevices() async throws -> [PhoneDevice] {
        [PhoneDevice(udid: "FAKE-0000-0000",
                     name: "iPhone (Тони)",
                     productType: "iPhone18,3",
                     transport: .wifi)]
    }

    func battery(for device: PhoneDevice) async throws -> BatteryStatus {
        BatteryStatus(percent: percent,
                      isCharging: isCharging,
                      externalConnected: isCharging,
                      fullyCharged: percent >= 100,
                      updatedAt: Date())
    }
}

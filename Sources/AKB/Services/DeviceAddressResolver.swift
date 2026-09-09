import Foundation

/// Запуск внешней утилиты. Отдельный протокол нужен ради тестов:
/// в них вместо `Process` подставляется таблица заранее заготовленных ответов.
protocol CommandExecutor: Sendable {
    /// `tool` — имя утилиты из `ToolLocator` (`akb-direct`) либо абсолютный путь (`/usr/sbin/arp`).
    func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult
}

struct SystemCommandExecutor: CommandExecutor {
    func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let url: URL
        if tool.hasPrefix("/") {
            url = URL(fileURLWithPath: tool)
        } else if let located = ToolLocator.locate(tool) {
            url = located
        } else {
            throw ProviderError.toolNotFound
        }
        return try await ProcessRunner.run(url, arguments: arguments, timeout: timeout)
    }
}

/// Где приложение помнит адрес телефона между запусками.
protocol AddressCache: Sendable {
    func ip(for udid: String) -> String?
    func setIP(_ ip: String?, for udid: String)
    func mac(for udid: String) -> String?
    func setMAC(_ mac: String?, for udid: String)
}

/// Рабочий кэш — `UserDefaults` (ключи `lastKnownIP`, `lastKnownMAC`).
struct PrefsAddressCache: AddressCache {
    func ip(for udid: String) -> String? { Prefs.lastKnownIP[udid] }
    func setIP(_ ip: String?, for udid: String) { Prefs.lastKnownIP[udid] = ip }
    func mac(for udid: String) -> String? { Prefs.lastKnownMAC[udid] }
    func setMAC(_ mac: String?, for udid: String) { Prefs.lastKnownMAC[udid] = mac }
}

/// Находит LAN-адрес телефона, который спит и потому не виден ни usbmuxd, ни Bonjour.
///
/// Цепочка (план §16.3), с остановкой на первом результате:
/// 1. кэш `lastKnownIP`;
/// 2. `akb-direct addr <udid>` — если usbmuxd прямо сейчас видит устройство по сети;
/// 3. `akb-direct mac <udid>` (MAC из записи сопряжения, тоже кэшируется) → `arp -an` → IP.
///
/// Ошибиться адресом почти безопасно: рукопожатие с чужим хостом не пройдёт —
/// запись сопряжения подходит ровно одному телефону. Провайдер, у которого окно
/// повторов закончилось ничем, зовёт `invalidate(_:)`, и следующий опрос ищет заново.
actor DeviceAddressResolver {

    /// Как ищется адрес — попадает в лог и нужно для приёмки §16.8.
    enum Source: String, Sendable {
        case cache
        case usbmuxd
        case arp
    }

    struct Resolved: Sendable, Equatable {
        var ip: String
        var source: Source
    }

    private let executor: CommandExecutor
    private let cache: AddressCache
    private let timeout: TimeInterval

    init(executor: CommandExecutor = SystemCommandExecutor(),
         cache: AddressCache = PrefsAddressCache(),
         timeout: TimeInterval = 8) {
        self.executor = executor
        self.cache = cache
        self.timeout = timeout
    }

    func resolve(udid: String) async -> Resolved? {
        if let cached = cache.ip(for: udid), ARPTable.isIPv4(cached) {
            return Resolved(ip: cached, source: .cache)
        }
        if let ip = await addressFromUSBMux(udid: udid) {
            cache.setIP(ip, for: udid)
            AKBLog.info(.resolver, "адрес из usbmuxd: \(ip)")
            return Resolved(ip: ip, source: .usbmuxd)
        }
        if let ip = await addressFromARP(udid: udid) {
            cache.setIP(ip, for: udid)
            AKBLog.info(.resolver, "адрес из arp: \(ip)")
            return Resolved(ip: ip, source: .arp)
        }
        AKBLog.info(.resolver, "адрес не найден для \(udid)")
        return nil
    }

    /// Телефон сейчас виден usbmuxd — самое время запомнить его адрес, пока он
    /// отдаётся даром. Спящий телефон из usbmuxd пропадает, и спросить будет уже некого.
    func warmCache(udid: String) async {
        guard cache.ip(for: udid) == nil else { return }
        guard let ip = await addressFromUSBMux(udid: udid) else { return }
        cache.setIP(ip, for: udid)
        AKBLog.info(.resolver, "адрес запомнен, пока телефон виден: \(ip)")
    }

    /// Кэш адреса больше не верен: телефон переехал или его тут нет.
    func invalidate(udid: String) {
        cache.setIP(nil, for: udid)
    }

    // MARK: - Шаги цепочки

    private func addressFromUSBMux(udid: String) async -> String? {
        guard let result = try? await executor.run("akb-direct", ["addr", udid], timeout: timeout) else {
            AKBLog.info(.resolver, "akb-direct addr не запустился")
            return nil
        }
        guard result.status == 0 else {
            AKBLog.debug(.resolver, "akb-direct addr: код \(result.status)")
            return nil
        }
        let ip = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return ARPTable.isIPv4(ip) ? ip : nil
    }

    private func addressFromARP(udid: String) async -> String? {
        guard let mac = await wifiMAC(udid: udid) else {
            AKBLog.info(.resolver, "MAC телефона неизвестен")
            return nil
        }
        guard let arp = try? await executor.run("/usr/sbin/arp", ["-an"], timeout: timeout),
              arp.status == 0 else {
            AKBLog.info(.resolver, "arp -an не отработал")
            return nil
        }
        guard let ip = ARPTable.address(of: mac, in: arp.stdout) else {
            AKBLog.info(.resolver, "в arp нет записи для \(mac)")
            return nil
        }
        return ip
    }


    /// MAC телефона в этой сети. Он фиксирован (Private Wi-Fi Address держится за сеть),
    /// поэтому читаем один раз и храним в кэше.
    private func wifiMAC(udid: String) async -> String? {
        if let cached = cache.mac(for: udid), let mac = ARPTable.normalize(cached) { return mac }
        guard let result = try? await executor.run("akb-direct", ["mac", udid], timeout: timeout) else {
            AKBLog.info(.resolver, "akb-direct mac не запустился")
            return nil
        }
        guard result.status == 0,
              let mac = ARPTable.normalize(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            AKBLog.info(.resolver, """
                akb-direct mac: код \(result.status), \
                \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                """)
            return nil
        }
        cache.setMAC(mac, for: udid)
        return mac
    }
}

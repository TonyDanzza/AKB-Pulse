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
    func hostname(for udid: String) -> String?
    func setHostname(_ hostname: String?, for udid: String)
    /// Когда по этому адресу последний раз получили ответ.
    func confirmedAt(for udid: String) -> Date?
    func setConfirmedAt(_ date: Date?, for udid: String)
}

/// Рабочий кэш — `UserDefaults`.
struct PrefsAddressCache: AddressCache {
    func ip(for udid: String) -> String? { Prefs.lastKnownIP[udid] }
    func setIP(_ ip: String?, for udid: String) { Prefs.lastKnownIP[udid] = ip }
    func mac(for udid: String) -> String? { Prefs.lastKnownMAC[udid] }
    func setMAC(_ mac: String?, for udid: String) { Prefs.lastKnownMAC[udid] = mac }
    func hostname(for udid: String) -> String? { Prefs.lastKnownHostname[udid] }
    func setHostname(_ hostname: String?, for udid: String) { Prefs.lastKnownHostname[udid] = hostname }
    func confirmedAt(for udid: String) -> Date? {
        Prefs.ipConfirmedAt[udid].map { Date(timeIntervalSince1970: $0) }
    }
    func setConfirmedAt(_ date: Date?, for udid: String) {
        Prefs.ipConfirmedAt[udid] = date?.timeIntervalSince1970
    }
}

/// Находит LAN-адрес телефона, который спит и потому не виден ни usbmuxd, ни Bonjour.
///
/// Адрес не забывается после одной неудачи (план §23.1): телефон отвечает волнами,
/// и промах окна повторов — это не смена адреса. Кэш перестаёт быть верным только
/// если другой путь нашёл другой IP или если по старому не отвечают дольше шести часов.
///
/// Поиск идёт тремя независимыми путями (план §23.2), потому что каждый из них
/// по отдельности отказывает: usbmuxd не видит спящий телефон, `arp` из приложения
/// приходит пустым, а имя хоста известно не сразу.
/// Порядок при потере адреса: кэш → mDNS по имени → таблица ARP по MAC → usbmuxd.
///
/// Ошибиться адресом почти безопасно: рукопожатие с чужим хостом не пройдёт —
/// запись сопряжения подходит ровно одному телефону.
actor DeviceAddressResolver {

    /// Как найден адрес — попадает в лог и нужно для приёмки §16.8, §23.3.
    enum Source: String, Sendable {
        case cache
        case hostname
        case arp
        case usbmuxd
    }

    struct Resolved: Sendable, Equatable {
        var ip: String
        var source: Source
    }

    /// Сколько адрес живёт без единого ответа (план §23.1в).
    static let addressLifetime: TimeInterval = 6 * 60 * 60

    private let executor: CommandExecutor
    private let cache: AddressCache
    private let names: HostnameResolving
    private let systemTable: @Sendable () -> [String: String]
    /// Есть ли вообще сеть: без неё пустая таблица ARP ничего не говорит
    /// о разрешении на локальную сеть (план §3).
    private let hasNetwork: @Sendable () -> Bool
    private let now: @Sendable () -> Date
    private let timeout: TimeInterval
    /// Когда последний раз искали имя телефона в Bonjour: поиск ждёт волну
    /// объявления до шести секунд, и делать это каждую минуту незачем.
    private var hostnameSearchedAt: [String: Date] = [:]

    init(executor: CommandExecutor = SystemCommandExecutor(),
         cache: AddressCache = PrefsAddressCache(),
         names: HostnameResolving = SystemHostnameResolver(),
         systemTable: @escaping @Sendable () -> [String: String] = { ARPTable.systemTable() },
         hasNetwork: @escaping @Sendable () -> Bool = { NetworkInterfaces.hasActiveIPv4() },
         now: @escaping @Sendable () -> Date = { Date() },
         timeout: TimeInterval = 8) {
        self.executor = executor
        self.cache = cache
        self.names = names
        self.systemTable = systemTable
        self.hasNetwork = hasNetwork
        self.now = now
        self.timeout = timeout
    }

    /// Адрес для опроса: сперва запомненный, иначе полный поиск.
    func resolve(udid: String) async -> Resolved? {
        if let cached = cache.ip(for: udid), ARPTable.isIPv4(cached) {
            return Resolved(ip: cached, source: .cache)
        }
        return await discover(udid: udid)
    }

    /// Поиск в обход кэша — три пути подряд (план §23.2). Любой успех обновляет кэш.
    func discover(udid: String) async -> Resolved? {
        if let ip = await addressFromHostname(udid: udid) {
            return remember(ip: ip, source: .hostname, udid: udid)
        }
        if let ip = await addressFromARP(udid: udid) {
            return remember(ip: ip, source: .arp, udid: udid)
        }
        if let ip = await addressFromUSBMux(udid: udid) {
            return remember(ip: ip, source: .usbmuxd, udid: udid)
        }
        AKBLog.info(.resolver, "адрес не найден для \(udid)")
        return nil
    }

    /// Телефон сейчас виден usbmuxd — самое время запомнить его адрес и имя, пока
    /// они отдаются даром. Спящий телефон из usbmuxd пропадает, и спросить будет некого.
    func warmCache(udid: String) async {
        if let ip = cache.ip(for: udid), ARPTable.isIPv4(ip) {
            await learnHostname(udid: udid, ip: ip, viaBonjour: true)
            return
        }
        guard let ip = await addressFromUSBMux(udid: udid) else { return }
        _ = remember(ip: ip, source: .usbmuxd, udid: udid)
        AKBLog.info(.resolver, "адрес запомнен, пока телефон виден: \(ip)")
        await learnHostname(udid: udid, ip: ip, viaBonjour: true)
    }

    /// По этому адресу только что прочитали заряд: он верен, часы жизни сброшены.
    func confirm(udid: String, ip: String) async {
        cache.setIP(ip, for: udid)
        cache.setConfirmedAt(now(), for: udid)
        await learnHostname(udid: udid, ip: ip)
    }

    /// Окно повторов кончилось ничем. Адрес при этом **не** забывается: телефон
    /// просто спал. Забываем, только если по нему не было ответа дольше шести часов.
    func noteFailure(udid: String) {
        guard let confirmed = cache.confirmedAt(for: udid) else {
            cache.setConfirmedAt(now(), for: udid)   // с этой минуты пошёл отсчёт
            return
        }
        let silence = now().timeIntervalSince(confirmed)
        guard silence > Self.addressLifetime else {
            AKBLog.debug(.resolver, "адрес сохраняю: молчит \(Int(silence / 60)) мин")
            return
        }
        AKBLog.info(.resolver, "адрес \(cache.ip(for: udid) ?? "—") молчит дольше 6 ч — забыт")
        invalidate(udid: udid)
    }

    /// Кэш адреса больше не верен.
    func invalidate(udid: String) {
        cache.setIP(nil, for: udid)
        cache.setConfirmedAt(nil, for: udid)
    }

    // MARK: - Шаги цепочки

    /// Запомнить найденный адрес; заодно сказать в лог, если он сменился.
    private func remember(ip: String, source: Source, udid: String) -> Resolved {
        if let previous = cache.ip(for: udid), previous != ip {
            AKBLog.info(.resolver, "адрес сменился: \(previous) → \(ip) (\(source.rawValue))")
            cache.setConfirmedAt(nil, for: udid)
        }
        cache.setIP(ip, for: udid)
        AKBLog.info(.resolver, "адрес из \(source.rawValue): \(ip)")
        return Resolved(ip: ip, source: source)
    }

    /// Путь 1: mDNS по сохранённому имени. Работает и с дремлющим телефоном.
    private func addressFromHostname(udid: String) async -> String? {
        guard let host = cache.hostname(for: udid), !host.isEmpty else {
            AKBLog.debug(.resolver, "имя хоста телефона неизвестно")
            return nil
        }
        guard let ip = await names.address(forHost: host, timeout: 5), ARPTable.isIPv4(ip) else {
            AKBLog.info(.resolver, "имя \(host) не разрешилось")
            return nil
        }
        return ip
    }

    /// Путь 2: таблица ARP по MAC из записи сопряжения.
    private func addressFromARP(udid: String) async -> String? {
        guard let mac = await wifiMAC(udid: udid) else {
            AKBLog.info(.resolver, "MAC телефона неизвестен")
            return nil
        }
        // Пустая запись в таблице оживает от одного пакета в сторону телефона.
        if let last = cache.ip(for: udid) {
            _ = try? await executor.run("/sbin/ping", ["-c1", "-W1000", "-t1", last], timeout: 3)
        }

        var table = await arpTableFromTool()
        if table.isEmpty {
            // Дочерний `arp` не получает разрешения на локальную сеть, а приложение
            // получает: тот же список читается своими руками через sysctl.
            table = systemTable()
            AKBLog.info(.resolver, "таблица из sysctl: записей \(table.count)")
            if table.isEmpty {
                // Без сети таблица пуста у кого угодно — это не запрет (план §3).
                let networkUp = hasNetwork()
                Prefs.localNetworkBlocked = networkUp
                if networkUp {
                    AKBLog.info(.resolver, """
                        таблица ARP пуста — похоже, приложению не разрешён доступ \
                        к локальной сети (Системные настройки → Конфиденциальность → Локальная сеть)
                        """)
                } else {
                    AKBLog.info(.resolver, "таблица ARP пуста, но и сети нет ни на одном интерфейсе")
                }
                return nil
            }
        }
        Prefs.localNetworkBlocked = false

        guard let ip = table[mac] else {
            AKBLog.info(.resolver, "в таблице ARP (записей \(table.count)) нет \(mac)")
            return nil
        }
        return ip
    }

    /// `arp -an` с диагностикой: по логу должно быть видно, пуст ли вывод и почему.
    private func arpTableFromTool() async -> [String: String] {
        guard let arp = try? await executor.run("/usr/sbin/arp", ["-an"], timeout: timeout) else {
            AKBLog.info(.resolver, "arp -an не запустился")
            return [:]
        }
        let table = ARPTable.parse(arp.stdout)
        AKBLog.info(.resolver, """
            arp -an: код \(arp.status), вывод \(arp.stdout.utf8.count) байт, \
            записей \(table.count)\
            \(arp.stderr.isEmpty ? "" : ", stderr: \(arp.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            """)
        return arp.status == 0 ? table : [:]
    }

    /// Путь 3: usbmuxd прямо сейчас видит устройство по сети.
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

    /// Имя хоста запоминается один раз и потом служит адресом спящего телефона.
    ///
    /// Сначала обратный резолв адреса; в домашней сети PTR-записи обычно нет,
    /// поэтому, пока телефон бодрствует (`viaBonjour`), имя спрашивается у его
    /// объявления `_apple-mobdev2._tcp`. Этот поиск ждёт волну до шести секунд,
    /// так что повторяем его не чаще раза в десять минут.
    private func learnHostname(udid: String, ip: String, viaBonjour: Bool = false) async {
        // Пустая строка — это не имя: её `addressFromHostname` всё равно отвергнет,
        // так что учим заново (план §9).
        guard (cache.hostname(for: udid) ?? "").isEmpty else { return }
        if let host = await names.hostname(forAddress: ip, timeout: 5) {
            return store(hostname: host, udid: udid)
        }
        guard viaBonjour else { return }
        if let last = hostnameSearchedAt[udid], now().timeIntervalSince(last) < 600 { return }
        hostnameSearchedAt[udid] = now()
        guard let mac = await wifiMAC(udid: udid),
              let host = await names.hostname(forMAC: mac, timeout: 6) else { return }
        store(hostname: host, udid: udid)
    }

    private func store(hostname: String, udid: String) {
        cache.setHostname(hostname, for: udid)
        AKBLog.info(.resolver, "имя телефона: \(hostname)")
    }
}

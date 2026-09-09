import Foundation
import Testing
@testable import AKB

/// Подставной исполнитель: отвечает по таблице «утилита + аргументы → вывод»
/// и запоминает порядок вызовов, чтобы проверить саму цепочку поиска.
private actor FakeExecutorState {
    var calls: [String] = []
    func record(_ call: String) { calls.append(call) }
}

private struct FakeExecutor: CommandExecutor {
    var responses: [String: ProcessResult]
    let state = FakeExecutorState()

    func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let call = ([tool] + arguments).joined(separator: " ")
        await state.record(call)
        guard let response = responses[call] else {
            return ProcessResult(status: 1, stdout: "", stderr: "not stubbed")
        }
        return response
    }
}

private func ok(_ text: String) -> ProcessResult {
    ProcessResult(status: 0, stdout: text + "\n", stderr: "")
}

private final class MemoryCache: AddressCache, @unchecked Sendable {
    private let lock = NSLock()
    private var ips: [String: String]
    private var macs: [String: String]
    private var hosts: [String: String]
    private var confirmed: [String: Date]

    init(ip: String? = nil,
         mac: String? = nil,
         hostname: String? = nil,
         confirmedAt: Date? = nil,
         udid: String = "UDID") {
        ips = ip.map { [udid: $0] } ?? [:]
        macs = mac.map { [udid: $0] } ?? [:]
        hosts = hostname.map { [udid: $0] } ?? [:]
        confirmed = confirmedAt.map { [udid: $0] } ?? [:]
    }

    func ip(for udid: String) -> String? { lock.withLock { ips[udid] } }
    func setIP(_ ip: String?, for udid: String) { lock.withLock { ips[udid] = ip } }
    func mac(for udid: String) -> String? { lock.withLock { macs[udid] } }
    func setMAC(_ mac: String?, for udid: String) { lock.withLock { macs[udid] = mac } }
    func hostname(for udid: String) -> String? { lock.withLock { hosts[udid] } }
    func setHostname(_ hostname: String?, for udid: String) { lock.withLock { hosts[udid] = hostname } }
    func confirmedAt(for udid: String) -> Date? { lock.withLock { confirmed[udid] } }
    func setConfirmedAt(_ date: Date?, for udid: String) { lock.withLock { confirmed[udid] = date } }
}

/// Подставной резолвер имён: таблица «имя → адрес» и «адрес → имя».
private struct FakeNames: HostnameResolving {
    var forward: [String: String] = [:]
    var reverse: [String: String] = [:]
    var byMAC: [String: String] = [:]

    func address(forHost host: String, timeout: TimeInterval) async -> String? { forward[host] }
    func hostname(forAddress ip: String, timeout: TimeInterval) async -> String? { reverse[ip] }
    func hostname(forMAC mac: String, timeout: TimeInterval) async -> String? { byMAC[mac] }
}

private let arpOutput = "? (192.168.1.11) at 34:10:be:d8:21:9 on en0 ifscope [ethernet]"

@Suite("Поиск адреса телефона")
struct DeviceAddressResolverTests {

    /// Резолвер без единого настоящего обращения к системе.
    private func makeResolver(_ executor: FakeExecutor,
                              cache: MemoryCache,
                              names: FakeNames = FakeNames(),
                              table: [String: String] = [:],
                              now: @escaping @Sendable () -> Date = { Date() }) -> DeviceAddressResolver {
        DeviceAddressResolver(executor: executor,
                              cache: cache,
                              names: names,
                              systemTable: { table },
                              now: now)
    }

    @Test("Шаг 1: кэш отвечает сразу, внешние утилиты не запускаются")
    func fromCache() async {
        let executor = FakeExecutor(responses: [:])
        let resolver = makeResolver(executor, cache: MemoryCache(ip: "192.168.1.11"))
        let resolved = await resolver.resolve(udid: "UDID")
        #expect(resolved == DeviceAddressResolver.Resolved(ip: "192.168.1.11", source: .cache))
        #expect(await executor.state.calls.isEmpty)
    }

    @Test("Шаг 2: адрес по сохранённому имени хоста через mDNS")
    func fromHostname() async {
        let executor = FakeExecutor(responses: [:])
        let cache = MemoryCache(hostname: "iPhone-Toni.local.")
        let names = FakeNames(forward: ["iPhone-Toni.local.": "192.168.1.11"])
        let resolver = makeResolver(executor, cache: cache, names: names)
        let resolved = await resolver.resolve(udid: "UDID")
        #expect(resolved?.source == .hostname)
        #expect(resolved?.ip == "192.168.1.11")
        #expect(cache.ip(for: "UDID") == "192.168.1.11")
        // Ни одна внешняя утилита не понадобилась.
        #expect(await executor.state.calls.isEmpty)
    }

    @Test("Шаг 3: имени нет — MAC из записи сопряжения и arp")
    func fromARP() async {
        let executor = FakeExecutor(responses: [
            "akb-direct mac UDID": ok("34:10:be:d8:21:09"),
            "/usr/sbin/arp -an": ok(arpOutput)
        ])
        let cache = MemoryCache()
        let resolver = makeResolver(executor, cache: cache)
        let resolved = await resolver.resolve(udid: "UDID")
        #expect(resolved?.ip == "192.168.1.11")
        #expect(resolved?.source == .arp)
        #expect(cache.ip(for: "UDID") == "192.168.1.11")
        #expect(cache.mac(for: "UDID") == "34:10:be:d8:21:09")
        #expect(await executor.state.calls == ["akb-direct mac UDID", "/usr/sbin/arp -an"])
    }

    @Test("Пустой arp: адрес берётся из маршрутной таблицы")
    func fromSystemTableWhenARPEmpty() async {
        let executor = FakeExecutor(responses: [
            "akb-direct mac UDID": ok("34:10:be:d8:21:09"),
            "/usr/sbin/arp -an": ok("")
        ])
        let resolver = makeResolver(executor,
                                    cache: MemoryCache(),
                                    table: ["34:10:be:d8:21:09": "192.168.1.11"])
        let resolved = await resolver.resolve(udid: "UDID")
        #expect(resolved?.ip == "192.168.1.11")
        #expect(resolved?.source == .arp)
        #expect(Prefs.localNetworkBlocked == false)
    }

    @Test("Пустая таблица целиком — подсказка про локальную сеть")
    func localNetworkHint() async {
        Prefs.localNetworkBlocked = false
        let executor = FakeExecutor(responses: [
            "akb-direct mac UDID": ok("34:10:be:d8:21:09"),
            "/usr/sbin/arp -an": ok("")
        ])
        let resolver = makeResolver(executor, cache: MemoryCache())
        #expect(await resolver.resolve(udid: "UDID") == nil)
        #expect(Prefs.localNetworkBlocked)
        Prefs.localNetworkBlocked = false
    }

    @Test("Шаг 4: usbmuxd видит телефон по сети — адрес оттуда, кэш обновлён")
    func fromUSBMux() async {
        let executor = FakeExecutor(responses: ["akb-direct addr UDID": ok("192.168.1.22")])
        let cache = MemoryCache()
        let resolver = makeResolver(executor, cache: cache, table: ["aa:bb:cc:dd:ee:ff": "10.0.0.1"])
        let resolved = await resolver.resolve(udid: "UDID")
        #expect(resolved?.ip == "192.168.1.22")
        #expect(resolved?.source == .usbmuxd)
        #expect(cache.ip(for: "UDID") == "192.168.1.22")
    }

    @Test("Известный MAC не перечитывается из записи сопряжения")
    func macFromCache() async {
        let executor = FakeExecutor(responses: ["/usr/sbin/arp -an": ok(arpOutput)])
        let resolver = makeResolver(executor, cache: MemoryCache(mac: "34:10:be:d8:21:09"))
        let resolved = await resolver.resolve(udid: "UDID")
        #expect(resolved?.ip == "192.168.1.11")
        #expect(await executor.state.calls == ["/usr/sbin/arp -an"])
    }

    @Test("Ничего не нашли")
    func nothing() async {
        let executor = FakeExecutor(responses: ["/usr/sbin/arp -an": ok(arpOutput)])
        let resolver = makeResolver(executor, cache: MemoryCache())
        #expect(await resolver.resolve(udid: "UDID") == nil)
    }

    @Test("MAC телефона есть, но в arp его нет — адреса нет")
    func macWithoutARPEntry() async {
        let executor = FakeExecutor(responses: [
            "akb-direct mac UDID": ok("aa:bb:cc:dd:ee:ff"),
            "/usr/sbin/arp -an": ok(arpOutput)
        ])
        let resolver = makeResolver(executor, cache: MemoryCache())
        #expect(await resolver.resolve(udid: "UDID") == nil)
    }

    // MARK: - Память об адресе (план §23.1)

    @Test("Неудачное окно повторов адрес не стирает")
    func failureKeepsAddress() async {
        let cache = MemoryCache(ip: "192.168.1.11", confirmedAt: Date())
        let resolver = makeResolver(FakeExecutor(responses: [:]), cache: cache)
        await resolver.noteFailure(udid: "UDID")
        #expect(cache.ip(for: "UDID") == "192.168.1.11")
    }

    @Test("Адрес, молчащий больше шести часов, забывается")
    func staleAddressForgotten() async {
        let confirmed = Date(timeIntervalSince1970: 0)
        let cache = MemoryCache(ip: "192.168.1.11", confirmedAt: confirmed)
        let resolver = makeResolver(FakeExecutor(responses: [:]),
                                    cache: cache,
                                    now: { confirmed.addingTimeInterval(7 * 60 * 60) })
        await resolver.noteFailure(udid: "UDID")
        #expect(cache.ip(for: "UDID") == nil)
    }

    @Test("Другой IP от резолвера заменяет кэш")
    func differentAddressReplacesCache() async {
        let cache = MemoryCache(ip: "192.168.1.11", hostname: "iPhone-Toni.local.")
        let names = FakeNames(forward: ["iPhone-Toni.local.": "192.168.1.77"])
        let resolver = makeResolver(FakeExecutor(responses: [:]), cache: cache, names: names)
        let resolved = await resolver.discover(udid: "UDID")
        #expect(resolved?.ip == "192.168.1.77")
        #expect(cache.ip(for: "UDID") == "192.168.1.77")
        #expect(cache.confirmedAt(for: "UDID") == nil)
    }

    @Test("Успешное чтение запоминает адрес и имя телефона")
    func confirmLearnsHostname() async {
        let cache = MemoryCache()
        let names = FakeNames(reverse: ["192.168.1.11": "iPhone-Toni.local."])
        let resolver = makeResolver(FakeExecutor(responses: [:]), cache: cache, names: names)
        await resolver.confirm(udid: "UDID", ip: "192.168.1.11")
        #expect(cache.ip(for: "UDID") == "192.168.1.11")
        #expect(cache.hostname(for: "UDID") == "iPhone-Toni.local.")
        #expect(cache.confirmedAt(for: "UDID") != nil)
    }

    @Test("Имя телефона узнаётся по MAC через Bonjour, когда PTR-записи нет")
    func learnsHostnameViaBonjour() async {
        let cache = MemoryCache(ip: "192.168.1.11", mac: "34:10:be:d8:21:09")
        let names = FakeNames(byMAC: ["34:10:be:d8:21:09": "iPhone-Toni.local."])
        let resolver = makeResolver(FakeExecutor(responses: [:]), cache: cache, names: names)
        await resolver.warmCache(udid: "UDID")
        #expect(cache.hostname(for: "UDID") == "iPhone-Toni.local.")
    }
}

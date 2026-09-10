import Foundation
import Testing

// Свои заглушки (одноимённые в DeviceAddressResolverTests — private для того файла).

private final class StubExecutor: CommandExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [String: ProcessResult]
    private var calls: [String] = []

    init(_ responses: [String: ProcessResult] = [:]) { self.responses = responses }

    var recorded: [String] { lock.withLock { calls } }

    func run(_ tool: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let call = ([tool] + arguments).joined(separator: " ")
        return lock.withLock {
            calls.append(call)
            return responses[call] ?? ProcessResult(status: 1, stdout: "", stderr: "not stubbed")
        }
    }
}

private func ok(_ text: String) -> ProcessResult { ProcessResult(status: 0, stdout: text + "\n", stderr: "") }
private func failed(_ text: String) -> ProcessResult { ProcessResult(status: 1, stdout: text + "\n", stderr: "") }

private final class StubCache: AddressCache, @unchecked Sendable {
    private let lock = NSLock()
    private var ips: [String: String] = [:]
    private var macs: [String: String] = [:]
    private var hosts: [String: String] = [:]
    private var confirmed: [String: Date] = [:]

    init(ip: String? = nil, mac: String? = nil, hostname: String? = nil, confirmedAt: Date? = nil) {
        if let ip { ips[udid] = ip }
        if let mac { macs[udid] = mac }
        if let hostname { hosts[udid] = hostname }
        if let confirmedAt { confirmed[udid] = confirmedAt }
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

/// Резолвер имён со счётчиками обращений.
private final class StubNames: HostnameResolving, @unchecked Sendable {
    private let lock = NSLock()
    var forward: [String: String] = [:]
    var reverse: [String: String] = [:]
    var byMAC: [String: String] = [:]
    private(set) var forwardCalls = 0
    private(set) var reverseCalls = 0
    private(set) var macCalls = 0

    init(forward: [String: String] = [:], reverse: [String: String] = [:], byMAC: [String: String] = [:]) {
        self.forward = forward
        self.reverse = reverse
        self.byMAC = byMAC
    }

    func address(forHost host: String, timeout: TimeInterval) async -> String? {
        lock.withLock { forwardCalls += 1; return forward[host] }
    }
    func hostname(forAddress ip: String, timeout: TimeInterval) async -> String? {
        lock.withLock { reverseCalls += 1; return reverse[ip] }
    }
    func hostname(forMAC mac: String, timeout: TimeInterval) async -> String? {
        lock.withLock { macCalls += 1; return byMAC[mac] }
    }
}

private final class StubClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.date = date }
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

private let udid = "UDID"
private let arpOutput = "? (192.168.1.11) at 34:10:be:d8:21:9 on en0 ifscope [ethernet]"

@Suite("Поиск адреса телефона: края")
struct DeviceAddressResolverEdgeTests {

    private func make(_ executor: StubExecutor = StubExecutor(),
                      cache: StubCache,
                      names: StubNames = StubNames(),
                      table: [String: String] = [:],
                      hasNetwork: @escaping @Sendable () -> Bool = { true },
                      clock: StubClock = StubClock()) -> DeviceAddressResolver {
        DeviceAddressResolver(executor: executor, cache: cache, names: names,
                              systemTable: { table }, hasNetwork: hasNetwork, now: clock.now)
    }

    @Test("Мусор в кэше адреса не считается адресом — идёт полный поиск")
    func garbageCachedIP() async {
        let cache = StubCache(ip: "не адрес", hostname: "iPhone-Toni.local.")
        let names = StubNames(forward: ["iPhone-Toni.local.": "192.168.1.11"])
        let resolver = make(cache: cache, names: names)
        let resolved = await resolver.resolve(udid: udid)
        #expect(resolved?.source == .hostname)
        #expect(cache.ip(for: udid) == "192.168.1.11")
    }

    @Test("Имя разрешилось в IPv6 — не подходит, идём дальше по цепочке")
    func hostnameGivesIPv6() async {
        let executor = StubExecutor(["/usr/sbin/arp -an": ok(arpOutput)])
        let cache = StubCache(mac: "34:10:be:d8:21:09", hostname: "iPhone-Toni.local.")
        let names = StubNames(forward: ["iPhone-Toni.local.": "fe80::3610:beff:fed8:2109"])
        let resolved = await make(executor, cache: cache, names: names).resolve(udid: udid)
        #expect(resolved?.source == .arp)
        #expect(resolved?.ip == "192.168.1.11")
    }

    @Test("Тот же адрес другим путём не сбрасывает дату подтверждения")
    func sameAddressKeepsConfirmation() async {
        let confirmed = Date(timeIntervalSince1970: 1_000)
        let cache = StubCache(ip: "192.168.1.11", hostname: "iPhone-Toni.local.", confirmedAt: confirmed)
        let names = StubNames(forward: ["iPhone-Toni.local.": "192.168.1.11"])
        _ = await make(cache: cache, names: names).discover(udid: udid)
        #expect(cache.confirmedAt(for: udid) == confirmed)
    }

    @Test("Первая неудача запускает отсчёт, шесть часов спустя адрес забыт")
    func failureClock() async {
        let clock = StubClock()
        let cache = StubCache(ip: "192.168.1.11")
        let resolver = make(cache: cache, clock: clock)

        await resolver.noteFailure(udid: udid)
        #expect(cache.ip(for: udid) == "192.168.1.11")
        #expect(cache.confirmedAt(for: udid) == clock.now())

        clock.advance(5 * 60 * 60)
        await resolver.noteFailure(udid: udid)
        #expect(cache.ip(for: udid) == "192.168.1.11")

        clock.advance(60 * 60 + 1)
        await resolver.noteFailure(udid: udid)
        #expect(cache.ip(for: udid) == nil)
        #expect(cache.confirmedAt(for: udid) == nil)
    }

    @Test("Ровно шесть часов молчания — адрес ещё жив")
    func exactlySixHoursKept() async {
        let clock = StubClock()
        let cache = StubCache(ip: "192.168.1.11", confirmedAt: clock.now())
        let resolver = make(cache: cache, clock: clock)
        clock.advance(DeviceAddressResolver.addressLifetime)
        await resolver.noteFailure(udid: udid)
        #expect(cache.ip(for: udid) == "192.168.1.11")
    }

    @Test("Подтверждение после забвения запускает отсчёт заново")
    func confirmAfterForget() async {
        let clock = StubClock()
        let cache = StubCache(ip: "192.168.1.11", confirmedAt: clock.now())
        let resolver = make(cache: cache, clock: clock)
        clock.advance(7 * 60 * 60)
        await resolver.noteFailure(udid: udid)
        #expect(cache.ip(for: udid) == nil)
        await resolver.confirm(udid: udid, ip: "192.168.1.11")
        #expect(cache.ip(for: udid) == "192.168.1.11")
        #expect(cache.confirmedAt(for: udid) == clock.now())
    }

    @Test("warmCache с известным адресом не трогает usbmuxd")
    func warmCacheKnownAddress() async {
        let executor = StubExecutor()
        let cache = StubCache(ip: "192.168.1.11", hostname: "iPhone-Toni.local.")
        await make(executor, cache: cache).warmCache(udid: udid)
        #expect(executor.recorded.isEmpty)
    }

    @Test("warmCache без адреса берёт его у usbmuxd и узнаёт имя")
    func warmCacheLearnsFromUSBMux() async {
        let executor = StubExecutor(["akb-direct addr UDID": ok("192.168.1.22")])
        let cache = StubCache()
        let names = StubNames(reverse: ["192.168.1.22": "iPhone-Toni.local."])
        await make(executor, cache: cache, names: names).warmCache(udid: udid)
        #expect(cache.ip(for: udid) == "192.168.1.22")
        #expect(cache.hostname(for: udid) == "iPhone-Toni.local.")
    }

    @Test("warmCache без помощника ничего не ломает")
    func warmCacheWithoutHelper() async {
        let cache = StubCache()
        await make(cache: cache).warmCache(udid: udid)
        #expect(cache.ip(for: udid) == nil)
        #expect(cache.hostname(for: udid) == nil)
    }

    @Test("Поиск имени через Bonjour не чаще раза в десять минут")
    func bonjourThrottled() async {
        let clock = StubClock()
        let cache = StubCache(ip: "192.168.1.11", mac: "34:10:be:d8:21:09")
        let names = StubNames()   // ни PTR, ни объявления — имя так и не найдётся
        let resolver = make(cache: cache, names: names, clock: clock)

        await resolver.warmCache(udid: udid)
        #expect(names.macCalls == 1)
        clock.advance(100)
        await resolver.warmCache(udid: udid)
        #expect(names.macCalls == 1)
        clock.advance(600)
        await resolver.warmCache(udid: udid)
        #expect(names.macCalls == 2)
    }

    @Test("Известное имя — никаких обратных резолвов")
    func knownHostnameSkipsLookups() async {
        let cache = StubCache(hostname: "iPhone-Toni.local.")
        let names = StubNames(reverse: ["192.168.1.11": "другое.local."])
        await make(cache: cache, names: names).confirm(udid: udid, ip: "192.168.1.11")
        #expect(names.reverseCalls == 0)
        #expect(cache.hostname(for: udid) == "iPhone-Toni.local.")
    }

    @Test("Перед чтением ARP телефон будят одним ping по старому адресу")
    func pingBeforeARP() async {
        let executor = StubExecutor(["/usr/sbin/arp -an": ok(arpOutput)])
        let cache = StubCache(ip: "192.168.1.11", mac: "34:10:be:d8:21:09")
        let resolved = await make(executor, cache: cache).discover(udid: udid)
        #expect(resolved?.source == .arp)
        #expect(executor.recorded == ["/sbin/ping -c1 -W1000 -t1 192.168.1.11", "/usr/sbin/arp -an"])
    }

    @Test("arp с ненулевым кодом — как пустой, берём sysctl")
    func arpNonZeroStatus() async {
        let executor = StubExecutor(["/usr/sbin/arp -an": failed(arpOutput)])
        let cache = StubCache(mac: "34:10:be:d8:21:09")
        let resolved = await make(executor, cache: cache, table: ["34:10:be:d8:21:09": "192.168.1.11"]).discover(udid: udid)
        #expect(resolved?.source == .arp)
        #expect(resolved?.ip == "192.168.1.11")
    }

    @Test("Мусор от akb-direct addr — адреса нет")
    func usbmuxGarbage() async {
        let executor = StubExecutor(["akb-direct addr UDID": ok("not an ip")])
        #expect(await make(executor, cache: StubCache()).discover(udid: udid) == nil)
    }

    @Test("MAC от помощника нормализуется и кэшируется")
    func macNormalized() async {
        let executor = StubExecutor([
            "akb-direct mac UDID": ok("34:10:BE:D8:21:9"),
            "/usr/sbin/arp -an": ok(arpOutput)
        ])
        let cache = StubCache()
        let resolved = await make(executor, cache: cache).discover(udid: udid)
        #expect(resolved?.ip == "192.168.1.11")
        #expect(cache.mac(for: udid) == "34:10:be:d8:21:09")
    }

    @Test("Помощник вернул не MAC — в кэш ничего не попадает")
    func badMACNotCached() async {
        let executor = StubExecutor(["akb-direct mac UDID": ok("nope")])
        let cache = StubCache()
        _ = await make(executor, cache: cache).discover(udid: udid)
        #expect(cache.mac(for: udid) == nil)
    }

    @Test("invalidate чистит адрес и дату, но не MAC и имя")
    func invalidateKeepsIdentity() async {
        let cache = StubCache(ip: "192.168.1.11", mac: "34:10:be:d8:21:09",
                              hostname: "iPhone-Toni.local.", confirmedAt: Date())
        await make(cache: cache).invalidate(udid: udid)
        #expect(cache.ip(for: udid) == nil)
        #expect(cache.confirmedAt(for: udid) == nil)
        #expect(cache.mac(for: udid) == "34:10:be:d8:21:09")
        #expect(cache.hostname(for: udid) == "iPhone-Toni.local.")
    }

    @Test("Новый адрес от usbmuxd заменяет старый и сбрасывает подтверждение")
    func usbmuxReplacesAddress() async {
        let executor = StubExecutor(["akb-direct addr UDID": ok("192.168.1.22")])
        let cache = StubCache(ip: "192.168.1.11", confirmedAt: Date())
        let resolved = await make(executor, cache: cache).discover(udid: udid)
        #expect(resolved == DeviceAddressResolver.Resolved(ip: "192.168.1.22", source: .usbmuxd))
        #expect(cache.ip(for: udid) == "192.168.1.22")
        #expect(cache.confirmedAt(for: udid) == nil)
    }

    @Test("Сети нет вообще — подсказка про локальную сеть не загорается")
    func noNetworkNoHint() async {
        let saved = Prefs.localNetworkBlocked
        defer { Prefs.localNetworkBlocked = saved }
        Prefs.localNetworkBlocked = false
        let executor = StubExecutor(["/usr/sbin/arp -an": ok("")])
        let cache = StubCache(mac: "34:10:be:d8:21:09")
        // Обе таблицы пусты, но и живого интерфейса нет: это не запрет (план §3).
        let resolved = await make(executor, cache: cache, hasNetwork: { false }).discover(udid: udid)
        #expect(resolved == nil)
        #expect(Prefs.localNetworkBlocked == false)
    }

    @Test("Пустое имя в кэше переучивается")
    func emptyHostnameRelearned() async {
        let cache = StubCache(hostname: "")
        let names = StubNames(reverse: ["192.168.1.11": "iPhone-Toni.local."])
        await make(cache: cache, names: names).confirm(udid: udid, ip: "192.168.1.11")
        #expect(cache.hostname(for: udid) == "iPhone-Toni.local.")
        #expect(names.reverseCalls == 1)
    }

    @Test("Кэш другого телефона не мешает")
    func perDeviceIsolation() async {
        let cache = StubCache(ip: "192.168.1.11")
        let resolver = make(cache: cache)
        #expect(await resolver.resolve(udid: "OTHER") == nil)
        #expect(await resolver.resolve(udid: udid)?.ip == "192.168.1.11")
    }
}

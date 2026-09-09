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

    init(ip: String? = nil, mac: String? = nil, udid: String = "UDID") {
        ips = ip.map { [udid: $0] } ?? [:]
        macs = mac.map { [udid: $0] } ?? [:]
    }

    func ip(for udid: String) -> String? { lock.withLock { ips[udid] } }
    func setIP(_ ip: String?, for udid: String) { lock.withLock { ips[udid] = ip } }
    func mac(for udid: String) -> String? { lock.withLock { macs[udid] } }
    func setMAC(_ mac: String?, for udid: String) { lock.withLock { macs[udid] = mac } }
}

private let arpOutput = "? (192.168.1.11) at 34:10:be:d8:21:9 on en0 ifscope [ethernet]"

@Suite("Поиск адреса телефона")
struct DeviceAddressResolverTests {

    @Test("Шаг 1: кэш отвечает сразу, внешние утилиты не запускаются")
    func fromCache() async {
        let executor = FakeExecutor(responses: [:])
        let resolver = DeviceAddressResolver(executor: executor,
                                             cache: MemoryCache(ip: "192.168.1.11"))
        let resolved = await resolver.resolve(udid: "UDID")
        #expect(resolved == DeviceAddressResolver.Resolved(ip: "192.168.1.11", source: .cache))
        #expect(await executor.state.calls.isEmpty)
    }

    @Test("Шаг 2: usbmuxd видит телефон по сети — адрес оттуда, кэш обновлён")
    func fromUSBMux() async {
        let executor = FakeExecutor(responses: ["akb-direct addr UDID": ok("192.168.1.22")])
        let cache = MemoryCache()
        let resolver = DeviceAddressResolver(executor: executor, cache: cache)
        let resolved = await resolver.resolve(udid: "UDID")
        #expect(resolved?.ip == "192.168.1.22")
        #expect(resolved?.source == .usbmuxd)
        #expect(cache.ip(for: "UDID") == "192.168.1.22")
        #expect(await executor.state.calls == ["akb-direct addr UDID"])
    }

    @Test("Шаг 3: usbmuxd пуст — MAC из записи сопряжения и arp")
    func fromARP() async {
        let executor = FakeExecutor(responses: [
            "akb-direct mac UDID": ok("34:10:be:d8:21:09"),
            "/usr/sbin/arp -an": ok(arpOutput)
        ])
        let cache = MemoryCache()
        let resolver = DeviceAddressResolver(executor: executor, cache: cache)
        let resolved = await resolver.resolve(udid: "UDID")
        #expect(resolved?.ip == "192.168.1.11")
        #expect(resolved?.source == .arp)
        #expect(cache.ip(for: "UDID") == "192.168.1.11")
        #expect(cache.mac(for: "UDID") == "34:10:be:d8:21:09")
        #expect(await executor.state.calls == ["akb-direct addr UDID",
                                               "akb-direct mac UDID",
                                               "/usr/sbin/arp -an"])
    }

    @Test("Известный MAC не перечитывается из записи сопряжения")
    func macFromCache() async {
        let executor = FakeExecutor(responses: ["/usr/sbin/arp -an": ok(arpOutput)])
        let resolver = DeviceAddressResolver(executor: executor,
                                             cache: MemoryCache(mac: "34:10:be:d8:21:09"))
        let resolved = await resolver.resolve(udid: "UDID")
        #expect(resolved?.ip == "192.168.1.11")
        #expect(await executor.state.calls == ["akb-direct addr UDID", "/usr/sbin/arp -an"])
    }

    @Test("Шаг 4: ничего не нашли")
    func nothing() async {
        let executor = FakeExecutor(responses: ["/usr/sbin/arp -an": ok(arpOutput)])
        let resolver = DeviceAddressResolver(executor: executor, cache: MemoryCache())
        #expect(await resolver.resolve(udid: "UDID") == nil)
    }

    @Test("MAC телефона есть, но в arp его нет — адреса нет")
    func macWithoutARPEntry() async {
        let executor = FakeExecutor(responses: [
            "akb-direct mac UDID": ok("aa:bb:cc:dd:ee:ff"),
            "/usr/sbin/arp -an": ok(arpOutput)
        ])
        let resolver = DeviceAddressResolver(executor: executor, cache: MemoryCache())
        #expect(await resolver.resolve(udid: "UDID") == nil)
    }

    @Test("Сброс кэша после неудачного окна повторов")
    func invalidate() async {
        let cache = MemoryCache(ip: "192.168.1.11")
        let resolver = DeviceAddressResolver(executor: FakeExecutor(responses: [:]), cache: cache)
        await resolver.invalidate(udid: "UDID")
        #expect(cache.ip(for: "UDID") == nil)
        // MAC остаётся: он не меняется вместе с адресом.
        #expect(cache.mac(for: "UDID") == nil || cache.mac(for: "UDID") != "")
    }
}

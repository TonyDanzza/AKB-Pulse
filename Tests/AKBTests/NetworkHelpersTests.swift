import Darwin
import Foundation
import Testing
@testable import AKB

/// Слушающий сокет на 127.0.0.1 со случайным портом.
private func listenOnLoopback() -> (fd: Int32, port: UInt16)? {
    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard "127.0.0.1".withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { close(fd); return nil }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(fd, 4) == 0 else { close(fd); return nil }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard named == 0 else { close(fd); return nil }
    return (fd, UInt16(bigEndian: address.sin_port))
}

@Suite("Проверка порта")
struct PortProbeTests {

    @Test("Открытый порт на localhost виден, закрытый — нет")
    func openAndClosed() async throws {
        let listener = try #require(listenOnLoopback())
        #expect(await PortProbe.isOpen(host: "127.0.0.1", port: listener.port, timeout: 2))
        close(listener.fd)
        // Порт освобождён: connect получает отказ, а не таймаут.
        let started = ContinuousClock.now
        #expect(await PortProbe.isOpen(host: "127.0.0.1", port: listener.port, timeout: 2) == false)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("Не-адрес — сразу false")
    func garbageHost() async {
        #expect(await PortProbe.isOpen(host: "iPhone-Toni.local", port: 62078, timeout: 1) == false)
        #expect(await PortProbe.isOpen(host: "", port: 62078, timeout: 1) == false)
    }

    @Test("Немаршрутизируемый адрес укладывается в таймаут")
    func unroutableTimesOut() async {
        let started = ContinuousClock.now
        // 192.0.2.0/24 (TEST-NET-1) никуда не ведёт.
        let open = await PortProbe.isOpen(host: "192.0.2.1", port: 62078, timeout: 0.5)
        #expect(ContinuousClock.now - started < .seconds(3))
        // Прозрачный прокси (VPN, «умный» DNS) принимает connect на любой адрес
        // и порт — тогда «закрыто» проверять нечем, остаётся только таймаут.
        let intercepted = await PortProbe.isOpen(host: "192.0.2.2", port: 9, timeout: 0.5)
        if !intercepted { #expect(open == false) }
    }
}

@Suite("Резолв имён")
struct HostnameResolverTests {

    @Test("localhost → 127.0.0.1")
    func forwardLocalhost() async {
        let resolver = SystemHostnameResolver()
        #expect(await resolver.address(forHost: "localhost", timeout: 5) == "127.0.0.1")
    }

    @Test("Несуществующее имя — nil, и не позже таймаута с запасом")
    func forwardMissing() async {
        let resolver = SystemHostnameResolver()
        let started = ContinuousClock.now
        let address = await resolver.address(forHost: "no-such-host-akb-tests.invalid", timeout: 2)
        #expect(ContinuousClock.now - started < .seconds(10))
        // «Умный» DNS (VPN, fake-ip) отвечает подставным адресом на любое имя,
        // включая заведомо случайное. Тогда проверять nil бессмысленно.
        let sentinel = await resolver.address(forHost: "akb-\(UUID().uuidString).invalid", timeout: 2)
        if sentinel == nil { #expect(address == nil) }
    }

    @Test("Обратный резолв мусора — nil")
    func reverseGarbage() async {
        let resolver = SystemHostnameResolver()
        #expect(await resolver.hostname(forAddress: "999.1.1.1", timeout: 2) == nil)
        #expect(await resolver.hostname(forAddress: "", timeout: 2) == nil)
    }

    @Test("Обратный резолв loopback не возвращает адрес вместо имени")
    func reverseLoopback() async {
        let resolver = SystemHostnameResolver()
        if let name = await resolver.hostname(forAddress: "127.0.0.1", timeout: 5) {
            #expect(ARPTable.isIPv4(name) == false)
            #expect(!name.isEmpty)
        }
    }
}

@Suite("Сетевые интерфейсы")
struct NetworkInterfacesTests {

    @Test("Опрос интерфейсов не падает и отвечает Bool")
    func doesNotCrash() {
        // Что именно ответит, зависит от машины: важно, что ответит.
        let answer = NetworkInterfaces.hasActiveIPv4()
        #expect(answer == true || answer == false)
    }
}

@Suite("Поиск утилит")
struct ToolLocatorTests {

    @Test("Системная утилита находится по стандартным путям")
    func findsSystemTool() throws {
        let url = try #require(ToolLocator.locate("true"))
        #expect(url.lastPathComponent == "true")
        #expect(FileManager.default.isExecutableFile(atPath: url.path))
        #expect(ToolLocator.searchPaths.contains(url.deletingLastPathComponent().path))
    }

    @Test("Неизвестная утилита — nil")
    func missingTool() {
        #expect(ToolLocator.locate("akb-no-such-tool-\(UUID().uuidString)") == nil)
    }

    @Test("Каталог утилит согласован с isAvailable")
    func consistency() {
        #expect(ToolLocator.isAvailable == (ToolLocator.resolvedDirectory != nil))
        if let directory = ToolLocator.resolvedDirectory {
            #expect(ToolLocator.searchPaths.contains(directory))
        }
    }
}

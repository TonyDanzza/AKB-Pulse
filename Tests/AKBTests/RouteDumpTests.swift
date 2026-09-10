import Darwin
import Foundation
import Testing
@testable import AKB

// Синтетический дамп маршрутов: те же байты, что отдаёт sysctl(CTL_NET, PF_ROUTE),
// но собранные руками — так разбор проверяется без зависимости от сети машины.

/// `sockaddr_in` (16 байт): len, family, port(2), addr(4), zero(8).
private func inet(_ ip: String) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 16)
    bytes[0] = 16
    bytes[1] = UInt8(AF_INET)
    let parts = ip.split(separator: ".").compactMap { UInt8($0) }
    precondition(parts.count == 4)
    for (index, part) in parts.enumerated() { bytes[4 + index] = part }
    return bytes
}

/// `sockaddr_in6` (28 байт) — IPv6-узел, разбору не интересен.
private func inet6() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 28)
    bytes[0] = 28
    bytes[1] = UInt8(AF_INET6)
    return bytes
}

/// `sockaddr_dl`: len, family, index(2), type, nlen, alen, slen, data[…].
/// Данные начинаются на восьмом байте: имя интерфейса, затем MAC.
private func link(mac: [UInt8]?, interface: String = "en0") -> [UInt8] {
    let name = Array(interface.utf8)
    let payload = name + (mac ?? [])
    let length = max(20, 8 + payload.count)
    var bytes = [UInt8](repeating: 0, count: length)
    bytes[0] = UInt8(length)
    bytes[1] = UInt8(AF_LINK)
    bytes[4] = 6                       // IFT_ETHER
    bytes[5] = UInt8(name.count)
    bytes[6] = UInt8(mac?.count ?? 0)
    for (index, byte) in payload.enumerated() { bytes[8 + index] = byte }
    return bytes
}

/// Одно сообщение `rt_msghdr` + адреса, каждый выровнен по 4 байта.
/// `addrs` — биты RTA_*: 0x1 узел, 0x2 шлюз, 0x4 маска.
private func message(_ addresses: [[UInt8]], addrs: Int32 = 0x3, msglen: Int? = nil) -> [UInt8] {
    let padded: [UInt8] = addresses.flatMap { address -> [UInt8] in
        let rounded = (address.count + 3) & ~3
        return address + [UInt8](repeating: 0, count: rounded - address.count)
    }
    var header = rt_msghdr()
    header.rtm_msglen = u_short(msglen ?? (MemoryLayout<rt_msghdr>.size + padded.count))
    header.rtm_version = 5             // RTM_VERSION
    header.rtm_type = 0x4              // RTM_GET
    header.rtm_addrs = addrs
    let headerBytes = withUnsafeBytes(of: header) { Array($0) }
    return headerBytes + padded
}

/// `sockaddr_dl`, который объявляет длину 8 (ни имени, ни адреса), но занимает
/// все шестнадцать оставшихся байт сообщения — так кончается настоящий дамп.
private func shortLink() -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 16)
    bytes[0] = 8                       // sdl_len
    bytes[1] = UInt8(AF_LINK)
    bytes[4] = 6                       // IFT_ETHER, sdl_nlen и sdl_alen нулевые
    return bytes
}

private let phoneMAC: [UInt8] = [0x34, 0x10, 0xbe, 0xd8, 0x21, 0x09]

@Suite("Разбор дампа маршрутов")
struct RouteDumpTests {

    @Test("Одна запись: IPv4 + MAC")
    func singleEntry() {
        let dump = message([inet("192.168.1.11"), link(mac: phoneMAC)])
        #expect(ARPTable.parseRouteDump(dump) == ["34:10:be:d8:21:09": "192.168.1.11"])
    }

    @Test("Запись без MAC (incomplete) пропускается")
    func incompleteSkipped() {
        let dump = message([inet("192.168.1.29"), link(mac: nil)])
        #expect(ARPTable.parseRouteDump(dump).isEmpty)
    }

    @Test("Несколько сообщений подряд; при дубле MAC побеждает первое")
    func multipleMessages() {
        let dump = message([inet("192.168.1.11"), link(mac: phoneMAC)])
            + message([inet("192.168.1.1"), link(mac: [0x54, 0xc2, 0x50, 0xf6, 0xd5, 0x90])])
            + message([inet("10.0.0.5"), link(mac: phoneMAC, interface: "en1")])
        let table = ARPTable.parseRouteDump(dump)
        #expect(table.count == 2)
        #expect(table["34:10:be:d8:21:09"] == "192.168.1.11")
        #expect(table["54:c2:50:f6:d5:90"] == "192.168.1.1")
    }

    @Test("IPv6-узел не попадает в таблицу")
    func ipv6Ignored() {
        let dump = message([inet6(), link(mac: phoneMAC)])
        #expect(ARPTable.parseRouteDump(dump).isEmpty)
    }

    @Test("Длинное имя интерфейса сдвигает MAC внутри sockaddr_dl")
    func longInterfaceName() {
        let dump = message([inet("192.168.64.2"), link(mac: phoneMAC, interface: "bridge100")])
            + message([inet("192.168.1.1"), link(mac: [1, 2, 3, 4, 5, 6])])
        let table = ARPTable.parseRouteDump(dump)
        #expect(table["34:10:be:d8:21:09"] == "192.168.64.2")
        #expect(table["01:02:03:04:05:06"] == "192.168.1.1")
    }

    @Test("Обрезанный хвост не ломает разбор предыдущих записей")
    func truncatedTail() {
        let whole = message([inet("192.168.1.11"), link(mac: phoneMAC)])
        let second = message([inet("192.168.1.1"), link(mac: [1, 2, 3, 4, 5, 6])])
        let dump = whole + Array(second.prefix(second.count - 5))
        #expect(ARPTable.parseRouteDump(dump) == ["34:10:be:d8:21:09": "192.168.1.11"])
    }

    @Test("Нулевая длина сообщения не зацикливает разбор")
    func zeroLengthMessage() {
        let dump = message([inet("192.168.1.11"), link(mac: phoneMAC)], msglen: 0)
            + message([inet("192.168.1.1"), link(mac: [1, 2, 3, 4, 5, 6])])
        // Достаточно, чтобы вызов вернулся; что именно он вернёт — не важно.
        _ = ARPTable.parseRouteDump(dump)
    }

    @Test("Маска без шлюза — MAC нет, запись пропускается")
    func netmaskWithoutGateway() {
        let dump = message([inet("192.168.1.0"), inet("255.255.255.0")], addrs: 0x5)
        #expect(ARPTable.parseRouteDump(dump).isEmpty)
    }

    @Test("Короткий sockaddr_dl в конце буфера не уводит чтение за границу")
    func shortLinkAtBufferEnd() {
        // Буфер кончается ровно на этом адресе: чтение sockaddr_dl целиком
        // (20 байт) ушло бы за его конец.
        let dump = message([inet("192.168.1.11"), shortLink()])
        #expect(ARPTable.parseRouteDump(dump).isEmpty)
    }

    @Test("MAC не берётся за границей своего сообщения")
    func macNotStolenFromNextMessage() {
        // Первому сообщению отдано ровно 16 байт под sockaddr_dl, а тот объявляет
        // длину 20 и alen 6: настоящие байты MAC лежат уже в следующей записи.
        let truncated = Array(link(mac: phoneMAC).prefix(16))
        let dump = message([inet("192.168.1.11"), truncated])
            + message([inet("192.168.1.1"), link(mac: [1, 2, 3, 4, 5, 6])])
        let table = ARPTable.parseRouteDump(dump)
        #expect(table == ["01:02:03:04:05:06": "192.168.1.1"])
    }

    @Test("Шлюз идёт после маски, если биты так говорят")
    func gatewayAfterNetmaskOrder() {
        // Биты 0 (узел), 1 (шлюз), 2 (маска): адреса лежат в порядке битов.
        let dump = message([inet("192.168.1.11"), link(mac: phoneMAC), inet("255.255.255.255")], addrs: 0x7)
        #expect(ARPTable.parseRouteDump(dump) == ["34:10:be:d8:21:09": "192.168.1.11"])
    }
}

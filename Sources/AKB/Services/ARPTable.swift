import Darwin
import Foundation

/// Разбор вывода `/usr/sbin/arp -an` — так мы находим IP телефона по MAC,
/// когда он спит и его не видно ни через usbmuxd, ни через Bonjour (план §16.3).
///
/// Строка выглядит так:
/// `? (192.168.1.11) at 34:10:be:d8:21:9 on en0 ifscope [ethernet]`
/// Обрати внимание: `arp` печатает MAC **без ведущих нулей** (`…:21:9`),
/// а запись сопряжения — с ними (`…:21:09`). Обе стороны нормализуем.
enum ARPTable {

    /// Приводит MAC к виду `aa:bb:cc:dd:ee:ff`. Возвращает nil, если это не MAC.
    static func normalize(_ raw: String) -> String? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var bytes: [String] = []
        bytes.reserveCapacity(6)
        for part in parts {
            guard !part.isEmpty, part.count <= 2, let value = UInt8(part, radix: 16) else { return nil }
            bytes.append(String(format: "%02x", value))
        }
        return bytes.joined(separator: ":")
    }

    /// Карта «нормализованный MAC → IPv4». При дублях побеждает первая строка:
    /// у `arp` записи по одному интерфейсу идут раньше «неполных» с других.
    static func parse(_ output: String) -> [String: String] {
        var table: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let open = line.firstIndex(of: "("),
                  let close = line[open...].firstIndex(of: ")") else { continue }
            let ip = String(line[line.index(after: open)..<close])
            guard isIPv4(ip) else { continue }

            let rest = line[line.index(after: close)...]
            let fields = rest.split(separator: " ")
            guard let atIndex = fields.firstIndex(of: "at"), atIndex + 1 < fields.count,
                  let mac = normalize(String(fields[atIndex + 1]))
            else { continue }   // `(incomplete)` и прочие записи без адреса

            if table[mac] == nil { table[mac] = ip }
        }
        return table
    }

    /// IP по MAC. Регистр и ведущие нули значения не имеют.
    static func address(of mac: String, in output: String) -> String? {
        guard let needle = normalize(mac) else { return nil }
        return parse(output)[needle]
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && UInt8(part) != nil
        }
    }

    // MARK: - Таблица без внешнего процесса (план §23.2)

    /// Та же таблица, что печатает `arp -an`, но прочитанная прямо в приложении
    /// через `sysctl(CTL_NET, PF_ROUTE, …)`. Нужна потому, что запущенный из
    /// приложения `/usr/sbin/arp` возвращает пустой вывод: доступ к локальной сети
    /// выдаётся конкретной программе, и дочерний процесс под него не подпадает.
    ///
    /// Спрашиваем тремя способами: `NET_RT_FLAGS` с `RTF_LLINFO` по IPv4, то же
    /// без указания семейства (на macOS 26 первый вариант отдаёт 0 байт) и, если
    /// и это пусто, полный `NET_RT_DUMP`.
    static func systemTable() -> [String: String] {
        let queries: [(af: Int32, kind: Int32, flags: Int32)] = [
            (AF_INET, NET_RT_FLAGS, Int32(RTF_LLINFO)),
            (AF_UNSPEC, NET_RT_FLAGS, Int32(RTF_LLINFO)),
            (AF_INET, NET_RT_DUMP, 0)
        ]
        for query in queries {
            guard let bytes = routeDump(af: query.af, kind: query.kind, flags: query.flags),
                  !bytes.isEmpty else { continue }
            let table = parseRouteDump(bytes)
            if !table.isEmpty { return table }
        }
        return [:]
    }

    /// Сырой ответ маршрутного sysctl.
    static func routeDump(af: Int32, kind: Int32, flags: Int32) -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, af, kind, flags]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let status = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, u_int(mib.count), raw.baseAddress, &size, nil, 0)
        }
        guard status == 0 else { return nil }
        return Array(buffer.prefix(size))
    }

    /// Разбор потока `rt_msghdr`. За заголовком идут адреса, какие именно —
    /// сказано битами `rtm_addrs`: нулевой бит это узел (IPv4), первый — шлюз,
    /// и у записей канального уровня в нём лежит MAC (`sockaddr_dl`).
    /// Записи без MAC — то же, что `(incomplete)` у `arp`, — пропускаются.
    static func parseRouteDump(_ bytes: [UInt8]) -> [String: String] {
        var table: [String: String] = [:]
        let headerSize = MemoryLayout<rt_msghdr>.size
        var offset = 0

        bytes.withUnsafeBytes { raw in
            while offset + headerSize <= raw.count {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let length = Int(header.rtm_msglen)
                guard length >= headerSize, offset + length <= raw.count else { break }

                var cursor = offset + headerSize
                // Всё читаем байтами и не выходим за границу текущего сообщения:
                // адрес может быть короче своей структуры (`sockaddr_dl` с длиной 8),
                // и загрузка её целиком ушла бы за конец буфера (план §2).
                let limit = offset + length
                var ip: String?
                var mac: String?
                for bit in 0..<8 where header.rtm_addrs & (1 << bit) != 0 {
                    guard cursor + 2 <= limit else { break }
                    let saLen = Int(raw[cursor])
                    let family = raw[cursor + 1]
                    guard saLen > 0, cursor + saLen <= limit else { break }
                    if bit == 0, family == UInt8(AF_INET), saLen >= 8 {
                        // sin_addr лежит на четвёртом байте: len, family, port(2), addr(4).
                        ip = (0..<4).map { String(raw[cursor + 4 + $0]) }.joined(separator: ".")
                    }
                    if bit == 1, family == UInt8(AF_LINK), saLen >= 8 {
                        let nlen = Int(raw[cursor + 5])
                        let alen = Int(raw[cursor + 6])
                        // sdl_data начинается на восьмом байте: сперва имя интерфейса, затем адрес.
                        let macOffset = cursor + 8 + nlen
                        if alen == 6, macOffset + 6 <= limit {
                            mac = (0..<6)
                                .map { String(format: "%02x", raw[macOffset + $0]) }
                                .joined(separator: ":")
                        }
                    }
                    cursor += roundup(saLen)
                }
                if let ip, let mac, isIPv4(ip), table[mac] == nil { table[mac] = ip }
                offset += length
            }
        }
        return table
    }

    /// Адреса в маршрутном сообщении выровнены по 4 байта.
    private static func roundup(_ length: Int) -> Int {
        let step = MemoryLayout<UInt32>.size
        guard length > 0 else { return step }
        return 1 + ((length - 1) | (step - 1))
    }
}

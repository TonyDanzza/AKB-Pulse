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
}

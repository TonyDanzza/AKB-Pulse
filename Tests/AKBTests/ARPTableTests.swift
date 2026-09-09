import Testing
@testable import AKB

/// Реальный вывод `arp -an` на машине пользователя: телефон — 192.168.1.11,
/// MAC напечатан без ведущего нуля в последнем байте (`:21:9`).
private let sample = """
? (192.168.1.1) at 54:c2:50:f6:d5:90 on en0 ifscope [ethernet]
? (192.168.1.10) at 7a:c0:c8:7d:f5:a8 on en0 ifscope permanent [ethernet]
? (192.168.1.11) at 34:10:be:d8:21:9 on en0 ifscope [ethernet]
? (192.168.1.29) at (incomplete) on en0 ifscope [ethernet]
? (192.168.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
"""

@Suite("Таблица ARP")
struct ARPTableTests {

    @Test("MAC нормализуется до aa:bb:cc:dd:ee:ff")
    func normalize() {
        #expect(ARPTable.normalize("34:10:be:d8:21:9") == "34:10:be:d8:21:09")
        #expect(ARPTable.normalize("34:10:BE:D8:21:09") == "34:10:be:d8:21:09")
        #expect(ARPTable.normalize("1:0:5e:0:0:fb") == "01:00:5e:00:00:fb")
        #expect(ARPTable.normalize("(incomplete)") == nil)
        #expect(ARPTable.normalize("34:10:be:d8:21") == nil)
        #expect(ARPTable.normalize("34:10:be:d8:21:9:7") == nil)
        #expect(ARPTable.normalize("zz:10:be:d8:21:09") == nil)
    }

    @Test("Разбор реального вывода arp -an")
    func parse() {
        let table = ARPTable.parse(sample)
        #expect(table["34:10:be:d8:21:09"] == "192.168.1.11")
        #expect(table["54:c2:50:f6:d5:90"] == "192.168.1.1")
        // Неполные записи в таблицу не попадают.
        #expect(table.values.contains("192.168.1.29") == false)
        #expect(table.count == 5)
    }

    @Test("Поиск по MAC не зависит от ведущих нулей и регистра")
    func lookup() {
        #expect(ARPTable.address(of: "34:10:be:d8:21:09", in: sample) == "192.168.1.11")
        #expect(ARPTable.address(of: "34:10:BE:D8:21:9", in: sample) == "192.168.1.11")
        #expect(ARPTable.address(of: "aa:bb:cc:dd:ee:ff", in: sample) == nil)
    }

    @Test("Несколько интерфейсов: побеждает первая запись")
    func multipleInterfaces() {
        let output = """
        ? (192.168.1.11) at 34:10:be:d8:21:9 on en0 ifscope [ethernet]
        ? (10.0.0.5) at 34:10:be:d8:21:9 on en1 ifscope [ethernet]
        ? (192.168.1.40) at (incomplete) on en1 [ethernet]
        """
        #expect(ARPTable.address(of: "34:10:be:d8:21:09", in: output) == "192.168.1.11")
    }

    @Test("Пустой и мусорный ввод")
    func garbage() {
        #expect(ARPTable.parse("").isEmpty)
        #expect(ARPTable.parse("совсем не таблица\nи ещё строка").isEmpty)
    }

    @Test("Проверка IPv4")
    func ipv4() {
        #expect(ARPTable.isIPv4("192.168.1.11"))
        #expect(ARPTable.isIPv4("0.0.0.0"))
        #expect(ARPTable.isIPv4("fe80::1") == false)
        #expect(ARPTable.isIPv4("192.168.1") == false)
        #expect(ARPTable.isIPv4("192.168.1.300") == false)
    }

    @Test("Маршрутная таблица системы читается без внешнего процесса")
    func systemTable() {
        // Содержимое зависит от сети, поэтому проверяем форму: ключи — MAC,
        // значения — IPv4. Пустой ответ допустим (машина может быть без сети).
        let table = ARPTable.systemTable()
        for (mac, ip) in table {
            #expect(ARPTable.normalize(mac) == mac)
            #expect(ARPTable.isIPv4(ip))
        }
    }

    @Test("Мусорный дамп маршрутов не роняет разбор")
    func garbageRouteDump() {
        #expect(ARPTable.parseRouteDump([]).isEmpty)
        #expect(ARPTable.parseRouteDump([UInt8](repeating: 0, count: 64)).isEmpty)
        #expect(ARPTable.parseRouteDump([1, 2, 3]).isEmpty)
    }
}

import Darwin
import Foundation

/// Резолв имени телефона в адрес и обратно (план §23.2, путь 1).
///
/// Спящий iPhone пропадает из usbmuxd и перестаёт публиковать `_apple-mobdev2._tcp`,
/// но mDNSResponder продолжает отвечать на его `.local`-имя — проверено на живом
/// телефоне (`dns-sd -G v4 iPhone-Toni.local.` → 192.168.1.11 за 4 с). Поэтому имя
/// хоста мы один раз узнаём обратным резолвом и потом держим в `Prefs`.
protocol HostnameResolving: Sendable {
    /// Имя → IPv4. `nil`, если имя не разрешилось за `timeout`.
    func address(forHost host: String, timeout: TimeInterval) async -> String?
    /// IPv4 → имя (`iPhone-Toni.local.`). `nil`, если PTR-записи нет.
    func hostname(forAddress ip: String, timeout: TimeInterval) async -> String?
    /// MAC → имя хоста через объявление Bonjour: работает, пока телефон бодрствует.
    func hostname(forMAC mac: String, timeout: TimeInterval) async -> String?
}

/// `getaddrinfo`/`getnameinfo` без внешних процессов (план §23.2).
///
/// Обе функции блокирующие и своего таймаута не имеют, поэтому они уходят на
/// фоновую очередь, а результат гонится с будильником: чей ответ придёт первым,
/// тот и вернётся. Брошенный вызов доработает сам и никому не помешает.
struct SystemHostnameResolver: HostnameResolving {

    func address(forHost host: String, timeout: TimeInterval) async -> String? {
        await race(timeout: timeout) { Self.forward(host) }
    }

    func hostname(forAddress ip: String, timeout: TimeInterval) async -> String? {
        await race(timeout: timeout) { Self.reverse(ip) }
    }

    func hostname(forMAC mac: String, timeout: TimeInterval) async -> String? {
        await BonjourHostname.lookup(mac: mac, timeout: timeout)
    }

    // MARK: - Гонка «ответ против будильника»

    /// Одноразовый ящик: `CheckedContinuation` нельзя разбудить дважды.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
        func resume(_ value: String?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    private func race(timeout: TimeInterval, work: @escaping @Sendable () -> String?) async -> String? {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            DispatchQueue.global(qos: .utility).async { once.resume(work()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { once.resume(nil) }
        }
    }

    // MARK: - POSIX

    /// Первый IPv4 из ответа `getaddrinfo`.
    private static func forward(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET          // нужен именно IPv4: помощник ходит по sockaddr_in
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let list else { return nil }
        defer { freeaddrinfo(list) }

        var node: UnsafeMutablePointer<addrinfo>? = list
        while let current = node {
            if let sa = current.pointee.ai_addr, current.pointee.ai_family == AF_INET {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, current.pointee.ai_addrlen,
                               &buffer, socklen_t(buffer.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = Self.text(buffer)
                    if ARPTable.isIPv4(ip) { return ip }
                }
            }
            node = current.pointee.ai_next
        }
        return nil
    }

    /// Строка до первого нуля из буфера `getnameinfo`.
    private static func text(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// PTR-запись адреса. Для `.local` отвечает mDNSResponder.
    private static func reverse(_ ip: String) -> String? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard ip.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &buffer, socklen_t(buffer.count),
                            nil, 0, NI_NAMEREQD)
            }
        }
        guard status == 0 else { return nil }
        let name = Self.text(buffer)
        // Числовой ответ — это не имя, а тот же адрес другими словами.
        return name.isEmpty || ARPTable.isIPv4(name) ? nil : name
    }
}

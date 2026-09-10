import Darwin
import Foundation

/// Есть ли у Mac хоть одна живая сеть по IPv4 (план §3).
///
/// Нужно, чтобы отличить «приложению не дали доступ к локальной сети» от
/// «сети нет вообще»: в обоих случаях таблица ARP пуста, но подсказка про
/// разрешение уместна только в первом.
enum NetworkInterfaces {

    /// Интерфейс не петлевой, поднят, работает и у него есть адрес IPv4.
    static func hasActiveIPv4() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }

        var current = list
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            guard !String(cString: entry.pointee.ifa_name).hasPrefix("lo") else { continue }
            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0 else { continue }
            return true
        }
        return false
    }
}

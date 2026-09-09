import Darwin
import Foundation

/// Дешёвая проверка «телефон сейчас слушает lockdownd?» (план §23.1).
///
/// Спящий iPhone держит порт 62078 открытым волнами: 5–15 с отвечает, 10–30 молчит.
/// Полный `akb-direct battery` — это TLS-рукопожатие и запуск процесса, поэтому
/// в окне повторов сначала стучимся обычным TCP-connect на секунду: он либо сразу
/// упирается в тишину, либо говорит, что волна пришла и пора читать заряд.
enum PortProbe {

    /// Порт lockdownd на iPhone.
    static let lockdownPort: UInt16 = 62078

    static func isOpen(host: String, port: UInt16 = lockdownPort, timeout: TimeInterval = 1) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: connect(host: host, port: port, timeout: timeout))
            }
        }
    }

    /// Неблокирующий connect + `poll`: соединение либо установится за `timeout`,
    /// либо мы его бросим, не дожидаясь системного таймаута в полторы минуты.
    private static func connect(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

        let started = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var event = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&event, 1, Int32(timeout * 1000)) == 1 else { return false }

        // `poll` будит и на отказ в соединении — настоящий итог лежит в SO_ERROR.
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }
}

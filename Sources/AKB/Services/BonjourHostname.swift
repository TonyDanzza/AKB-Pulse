import Foundation
import dnssd

/// Узнаёт `.local`-имя телефона по его Wi-Fi MAC (план §23.2, путь 1).
///
/// Обратный резолв адреса (`getnameinfo`) в домашней сети имя не даёт: PTR-записи
/// для 192.168.1.11 в mDNS попросту нет — проверено `dns-sd -Q 11.1.168.192.in-addr.arpa`.
/// Зато пока телефон бодрствует, он объявляет службу `_apple-mobdev2._tcp`, и имя
/// экземпляра начинается ровно с его MAC:
///
///     34:10:be:d8:21:09@fe80::3610:beff:fed8:2109-supportsRP-26._apple-mobdev2._tcp.local.
///     → can be reached at iPhone-Toni.local.:32498
///
/// Имя запоминается один раз и потом служит адресом для спящего телефона:
/// на `.local` mDNSResponder отвечает и тогда, когда службы уже не видно.
enum BonjourHostname {

    static let serviceType = "_apple-mobdev2._tcp"

    /// `nil`, если за `timeout` телефон не объявился (он спит) или имя не разрешилось.
    static func lookup(mac: String, timeout: TimeInterval = 6) async -> String? {
        await withCheckedContinuation { continuation in
            let search = Search(mac: mac, continuation: continuation)
            search.start(timeout: timeout)
        }
    }

    /// Один поиск: браузер ищет экземпляр с нужным MAC, резолв достаёт имя хоста.
    /// Всё живёт на своей очереди, ей же принадлежат оба `DNSServiceRef`.
    private final class Search: @unchecked Sendable {
        private let mac: String
        private let queue = DispatchQueue(label: "ru.tonydanzza.akb.bonjour")
        private var continuation: CheckedContinuation<String?, Never>?
        private var browse: DNSServiceRef?
        private var resolve: DNSServiceRef?

        init(mac: String, continuation: CheckedContinuation<String?, Never>) {
            self.mac = mac.lowercased()
            self.continuation = continuation
        }

        func start(timeout: TimeInterval) {
            queue.async { [self] in
                // Объект должен жить, пока dnssd может позвать обратный вызов:
                // ссылку отдаёт `finish`, а он выполняется ровно один раз (план §13).
                let context = Unmanaged.passRetained(self).toOpaque()
                var ref: DNSServiceRef?
                let status = DNSServiceBrowse(&ref, 0, 0, BonjourHostname.serviceType, nil,
                                              BonjourHostname.browseReply, context)
                guard status == kDNSServiceErr_NoError, let ref else { return finish(nil) }
                browse = ref
                DNSServiceSetDispatchQueue(ref, queue)
                queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(nil) }
            }
        }

        /// Нашли экземпляр — если это наш телефон, спрашиваем его имя хоста.
        func found(name: String, type: String, domain: String, interface: UInt32) {
            guard continuation != nil, resolve == nil, name.lowercased().hasPrefix(mac) else { return }
            var ref: DNSServiceRef?
            // Тот же объект, что и в браузере: второй сильной ссылки не нужно.
            let context = Unmanaged.passUnretained(self).toOpaque()
            let status = DNSServiceResolve(&ref, 0, interface, name, type, domain,
                                               BonjourHostname.resolveReply, context)
            guard status == kDNSServiceErr_NoError, let ref else { return }
            resolve = ref
            DNSServiceSetDispatchQueue(ref, queue)
        }

        func finish(_ hostname: String?) {
            guard let pending = continuation else { return }
            continuation = nil
            // Закрываем запросы следующим шагом очереди: `finish` вызывается
            // и изнутри обратного вызова dnssd, а рвать соединение под собой не стоит.
            queue.async { [self] in
                if let browse { DNSServiceRefDeallocate(browse) }
                if let resolve { DNSServiceRefDeallocate(resolve) }
                browse = nil
                resolve = nil
            }
            // Ссылка из `start` больше не нужна: замыкание выше держит объект
            // сильно до самого DNSServiceRefDeallocate.
            Unmanaged.passUnretained(self).release()
            pending.resume(returning: hostname)
        }
    }

    // Обратные вызовы dnssd — обычные C-функции, поэтому объект передаётся контекстом.

    private static let browseReply: DNSServiceBrowseReply = { _, _, interface, error, name, type, domain, context in
        guard error == kDNSServiceErr_NoError,
              let context, let name, let type, let domain else { return }
        Unmanaged<Search>.fromOpaque(context).takeUnretainedValue()
            .found(name: String(cString: name),
                   type: String(cString: type),
                   domain: String(cString: domain),
                   interface: interface)
    }

    private static let resolveReply: DNSServiceResolveReply = { _, _, _, error, _, host, _, _, _, context in
        guard let context else { return }
        let search = Unmanaged<Search>.fromOpaque(context).takeUnretainedValue()
        guard error == kDNSServiceErr_NoError, let host else { return search.finish(nil) }
        search.finish(String(cString: host))
    }
}

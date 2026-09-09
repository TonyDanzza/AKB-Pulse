import AppKit

/// Проверка существования SF Symbol в рантайме (план §5.1).
/// Возвращает первое имя из списка, которое реально есть в системе.
enum SymbolName {

    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static func resolve(_ candidates: String...) -> String {
        resolve(candidates)
    }

    static func resolve(_ candidates: [String]) -> String {
        let key = candidates.joined(separator: "|")
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let found = candidates.first { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
            ?? "questionmark.square.dashed"
        cache[key] = found
        return found
    }

    /// iPhone. `iphone.gen3` есть на macOS 27; запасной — `iphone`.
    static var phone: String { resolve("iphone.gen3", "iphone") }

    /// iPhone не найден.
    static var phoneSlash: String { resolve("iphone.gen3.slash", "iphone.slash") }

    /// Молния «заряжается». Отдельный символ: `iphone.gen3.badge.bolt` в macOS 27 ОТСУТСТВУЕТ.
    static var bolt: String { resolve("bolt.fill", "bolt") }

    static var warning: String { resolve("exclamationmark.triangle", "exclamationmark.triangle.fill") }
    static var refresh: String { resolve("arrow.clockwise") }
    static var settings: String { resolve("gearshape", "gear") }
    static var quit: String { resolve("power") }
    static var copy: String { resolve("doc.on.doc") }
    static var folder: String { resolve("folder") }
}

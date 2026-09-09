import Foundation

/// Поиск бинарников libimobiledevice: сначала путь из настроек, затем стандартные каталоги.
enum ToolLocator {

    static let defaultSearchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin"
    ]

    /// Каталог, заданный пользователем в настройках (кнопка «Указать путь…»).
    static var customDirectory: String? {
        get { UserDefaults.standard.string(forKey: Prefs.Key.toolDirectory) }
        set { UserDefaults.standard.set(newValue, forKey: Prefs.Key.toolDirectory) }
    }

    static var searchPaths: [String] {
        if let custom = customDirectory, !custom.isEmpty {
            return [custom] + defaultSearchPaths
        }
        return defaultSearchPaths
    }

    /// Возвращает URL исполняемого файла или nil.
    static func locate(_ name: String) -> URL? {
        if FakeMode.forceToolMissing { return nil }
        let fm = FileManager.default
        for directory in searchPaths {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Каталог, в котором реально найдены обе утилиты (для строки состояния в настройках).
    static var resolvedDirectory: String? {
        guard let idevice = locate("idevice_id"), locate("ideviceinfo") != nil else { return nil }
        return idevice.deletingLastPathComponent().path
    }

    static var isAvailable: Bool { resolvedDirectory != nil }
}

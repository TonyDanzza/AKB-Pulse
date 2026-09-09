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

    /// Утилиты, встроенные в бандл (`AKB.app/Contents/Helpers`) — фаза 2 плана.
    /// Приоритетнее всего: с ними приложению не нужен Homebrew.
    static var bundledDirectory: String? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url.path
    }

    /// Порядок поиска: бандл → путь из настроек → стандартные каталоги.
    static var searchPaths: [String] {
        var paths: [String] = []
        if let bundled = bundledDirectory { paths.append(bundled) }
        if let custom = customDirectory, !custom.isEmpty { paths.append(custom) }
        return paths + defaultSearchPaths
    }

    /// Утилиты взяты из бандла, а не из системы.
    static var isBundled: Bool {
        guard let bundled = bundledDirectory else { return false }
        return resolvedDirectory == bundled
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

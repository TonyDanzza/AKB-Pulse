import Foundation

/// Чистый парсер текстового вывода утилит libimobiledevice.
/// Не выполняет ввод-вывод — целиком покрыт тестами.
enum IMobileDeviceOutputParser {

    /// Разбирает вывод вида `Key: value` в словарь.
    /// Пустые строки и строки без двоеточия игнорируются.
    static func keyValues(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    /// Разбирает булево значение в формате ideviceinfo (`true`/`false`, а также `1`/`0`, `YES`/`NO`).
    static func bool(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true", "1", "yes": return true
        default: return false
        }
    }

    /// Разбирает вывод `ideviceinfo -q com.apple.mobile.battery`.
    /// Возвращает nil, если ключ `BatteryCurrentCapacity` отсутствует или не число.
    static func battery(_ text: String, now: Date = Date()) -> BatteryStatus? {
        let kv = keyValues(text)
        guard let capacityRaw = kv["BatteryCurrentCapacity"],
              let capacity = Int(capacityRaw.trimmingCharacters(in: .whitespaces))
        else { return nil }

        return BatteryStatus(
            percent: capacity,
            isCharging: bool(kv["BatteryIsCharging"]),
            externalConnected: bool(kv["ExternalConnected"]),
            fullyCharged: bool(kv["FullyCharged"]),
            updatedAt: now
        )
    }

    /// Разбирает вывод `akb-direct health` — плоские строки `Key: value`
    /// из записи IORegistry `AppleSmartBattery` (план §6.3).
    ///
    /// Возвращает nil, если нет циклов или ёмкостей: без них показывать нечего,
    /// а гадать по неполному ответу незнакомой прошивки — хуже, чем промолчать.
    static func health(_ text: String, now: Date = Date()) -> BatteryHealth? {
        let kv = keyValues(text)
        func int(_ key: String) -> Int? {
            guard let raw = kv[key] else { return nil }
            return Int(raw.trimmingCharacters(in: .whitespaces))
        }

        guard let cycleCount = int("CycleCount"),
              let designCapacity = int("DesignCapacity"), designCapacity > 0,
              let nominalCapacity = int("NominalChargeCapacity")
        else { return nil }

        // 65535 — «не знаю»: телефон так отвечает, пока не пересчитал прогноз.
        var timeRemaining = int("TimeRemaining")
        if let value = timeRemaining, value <= 0 || value == 65535 { timeRemaining = nil }

        return BatteryHealth(
            cycleCount: cycleCount,
            designCapacity: designCapacity,
            nominalCapacity: nominalCapacity,
            fullChargeCapacity: int("FullChargeCapacity"),
            voltage: int("Voltage"),
            // Мгновенный ток честнее усреднённого; если его нет — берём усреднённый.
            amperage: int("InstantAmperage") ?? int("Amperage"),
            // Температура приходит в сотых долях градуса: 2850 → 28,5 °C.
            temperature: int("Temperature").map { Double($0) / 100 },
            timeRemaining: timeRemaining,
            updatedAt: now
        )
    }

    /// Разбирает вывод `idevice_id -l` / `-n`: по одному UDID на строку.
    /// Строки с пробелами (сообщения об ошибках, «No device found.») отбрасываются.
    static func udidList(_ text: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.contains(" "), line.count >= 8 else { continue }
            let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
            guard line.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { continue }
            if seen.insert(line).inserted { result.append(line) }
        }
        return result
    }

    /// Разбирает вывод `ideviceinfo -k <Key>`: одна строка со значением.
    static func singleValue(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: "\n").first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}

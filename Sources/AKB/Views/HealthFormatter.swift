import Foundation

/// Числа здоровья батареи словами и знаками (план §6.8).
///
/// Вынесено из вида отдельным чистым перечислением: единственный способ проверить
/// тестами, что запятая и неразрывный пробел на месте.
/// Локаль передаётся явно — иначе тест зависел бы от настроек Mac.
///
/// Слова вокруг чисел («из», «мА·ч», «цикла») даёт обычная локализация приложения.
enum HealthFormatter {

    /// «3609 из 3654 мА·ч» — сколько держит батарея сейчас против новой.
    static func capacityLine(_ health: BatteryHealth, locale: Locale = .current) -> String {
        String(format: L("health.capacity.line", "%1$@ из %2$@ мА·ч"),
               integer(health.nominalCapacity, locale: locale),
               integer(health.designCapacity, locale: locale))
    }

    /// «99 %» — неразрывный пробел перед знаком, чтобы процент не уехал на строку ниже.
    static func percent(_ value: Int, locale: Locale = .current) -> String {
        "\(integer(value, locale: locale))\u{00A0}%"
    }

    /// «243 цикла» — правильная русская форма выбирается по числу.
    static func cycles(_ count: Int) -> String {
        String(localized: "health.cycles", defaultValue: "\(count) цикла")
    }

    /// Целое без разделителя тысяч: «3609», а не «3 609». Ёмкость читается как
    /// одно число, а не как две группы, и строка не расползается по ширине.
    static func integer(_ value: Int, locale: Locale = .current) -> String {
        numberFormatter(locale: locale, fractionDigits: 0).string(from: NSNumber(value: value))
            ?? String(value)
    }

    // MARK: - Внутреннее

    private static func numberFormatter(locale: Locale, fractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        // CLDR по умолчанию даёт дефис; для отрицательных чисел нужен настоящий минус.
        formatter.minusSign = "\u{2212}"
        return formatter
    }
}

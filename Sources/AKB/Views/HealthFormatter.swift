import Foundation

/// Числа здоровья батареи словами и знаками (план §6.8).
///
/// Вынесено из вида отдельным чистым перечислением: единственный способ проверить
/// тестами, что запятая, неразрывный пробел и настоящий минус на месте.
/// Локаль передаётся явно — иначе тест зависел бы от настроек Mac.
///
/// Единицы («В», «мА», «°C») даёт `MeasurementFormatter` по этой же локали,
/// а слова вокруг чисел («из», «мА·ч») — обычная локализация приложения.
enum HealthFormatter {

    /// «3609 из 3654 мА·ч» — сколько держит батарея сейчас против новой.
    static func capacityLine(_ health: BatteryHealth, locale: Locale = .current) -> String {
        String(format: L("health.capacity.line", "%1$@ из %2$@ мА·ч"),
               integer(health.nominalCapacity, locale: locale),
               integer(health.designCapacity, locale: locale))
    }

    /// «4,20 В» / «4.20 V». На входе милливольты, как их отдаёт телефон.
    static func voltage(_ millivolts: Int, locale: Locale = .current) -> String {
        measurement(Measurement(value: Double(millivolts) / 1000,
                                unit: UnitElectricPotentialDifference.volts),
                    locale: locale, fractionDigits: 2)
    }

    /// «−58 мА»: минус настоящий (U+2212), а не дефис.
    static func amperage(_ milliamps: Int, locale: Locale = .current) -> String {
        measurement(Measurement(value: Double(milliamps), unit: UnitElectricCurrent.milliamperes),
                    locale: locale, fractionDigits: 0)
    }

    /// «28,5 °C». iPhone 17 температуру не отдаёт, но если отдаст — покажем.
    static func temperature(_ celsius: Double, locale: Locale = .current) -> String {
        measurement(Measurement(value: celsius, unit: UnitTemperature.celsius),
                    locale: locale, fractionDigits: 1)
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

    private static func measurement(_ value: Measurement<some Dimension>,
                                    locale: Locale,
                                    fractionDigits: Int) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        // .providedUnit: милливольты нам самим не нужны, а фунты и Фаренгейт — тем более.
        formatter.unitOptions = [.providedUnit]
        formatter.unitStyle = .medium
        formatter.numberFormatter = numberFormatter(locale: locale, fractionDigits: fractionDigits)
        return formatter.string(from: value)
    }

    private static func numberFormatter(locale: Locale, fractionDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        // CLDR по умолчанию даёт дефис; в тексте о токе нужен знак минуса.
        formatter.minusSign = "\u{2212}"
        return formatter
    }
}

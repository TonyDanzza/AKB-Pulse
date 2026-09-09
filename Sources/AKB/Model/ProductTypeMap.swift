import Foundation

/// Соответствие Apple ProductType (`iPhone18,3`) человеческому имени модели.
///
/// Значения ниже, помеченные `// unverified`, не удалось подтвердить документально —
/// они оставлены как есть по требованию плана (§6): лучше показать сырой ProductType,
/// чем выдумать модель.
enum ProductTypeMap {

    static let table: [String: String] = [
        // iPhone 17 (2025). Ориентиры из плана §6.
        "iPhone18,1": "iPhone 17 Pro",        // unverified
        "iPhone18,2": "iPhone 17 Pro Max",    // unverified
        "iPhone18,3": "iPhone 17",            // unverified
        "iPhone18,4": "iPhone Air",           // unverified

        // iPhone 16 (2024).
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",           // unverified

        // iPhone 15 (2023).
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",

        // iPhone 14 (2022) — добавлено сверх минимума, значения широко известны.
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus"
    ]

    /// Возвращает человеческое имя модели либо сам ProductType, если он неизвестен.
    static func displayName(for productType: String) -> String {
        let key = productType.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return "iPhone" }
        return table[key] ?? key
    }

    /// Известна ли модель точно.
    static func isKnown(_ productType: String) -> Bool {
        table[productType.trimmingCharacters(in: .whitespacesAndNewlines)] != nil
    }
}

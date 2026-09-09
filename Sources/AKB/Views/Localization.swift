import Foundation

/// Короткая обёртка над `String(localized:defaultValue:)`.
/// Ключ — стабильный идентификатор, значение — русский исходный текст (язык разработки — ru).
/// Английские переводы лежат в `Resources/Localizable.xcstrings`.
@inline(__always)
func L(_ key: StaticString, _ value: String.LocalizationValue) -> String {
    String(localized: key, defaultValue: value)
}

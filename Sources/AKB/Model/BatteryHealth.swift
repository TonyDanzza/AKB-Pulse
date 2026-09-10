import Foundation

/// Здоровье батареи телефона: то же, что в iOS «Настройки → Батарея → Состояние»,
/// плюс сырые цифры из записи IORegistry `AppleSmartBattery` (план §6).
///
/// Меняется медленно (циклы — раз в сутки-двое), поэтому читается раз в час
/// и хранится в `UserDefaults` между запусками: показать вчерашние 99 % с датой
/// честнее, чем пустоту, пока телефон спит.
///
/// Серийного номера батареи здесь нет и не будет: помощник его не печатает.
struct BatteryHealth: Sendable, Equatable, Hashable, Codable {

    /// Число циклов зарядки.
    var cycleCount: Int
    /// Проектная ёмкость новой батареи, мА·ч.
    var designCapacity: Int
    /// Текущая полная ёмкость, мА·ч (`NominalChargeCapacity`) — по ней iOS считает проценты.
    var nominalCapacity: Int
    /// Ещё одна оценка полной ёмкости, мА·ч (`FullChargeCapacity`).
    var fullChargeCapacity: Int?
    /// Напряжение, мВ. В интерфейсе не показывается — остаётся для лога и разбора проблем.
    var voltage: Int?
    /// Ток, мА. Минус — разряд. В интерфейсе не показывается.
    var amperage: Int?
    /// Температура, °C. На iOS 26 телефон её не отдаёт — обычно nil.
    /// В интерфейсе не показывается.
    var temperature: Double?
    /// Минут до разряда. nil, если телефон ответил «не знаю» (65535) или числом ≤ 0.
    var timeRemaining: Int?
    /// Сырое `ChargerData.NotChargingReason`: почему зарядка стоит при воткнутом
    /// проводе. Разбирается через `isAtChargeLimit` (план §7.2).
    var notChargingReason: Int?
    /// Часы Mac в момент чтения: `UpdateTime` телефона живёт по своим часам.
    var updatedAt: Date
    /// Каким путём получено — для лога, как у `BatteryStatus`.
    var source: BatteryStatus.Source

    init(cycleCount: Int,
         designCapacity: Int,
         nominalCapacity: Int,
         fullChargeCapacity: Int? = nil,
         voltage: Int? = nil,
         amperage: Int? = nil,
         temperature: Double? = nil,
         timeRemaining: Int? = nil,
         notChargingReason: Int? = nil,
         updatedAt: Date = Date(),
         source: BatteryStatus.Source = .usbmuxd) {
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.nominalCapacity = nominalCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.voltage = voltage
        self.amperage = amperage
        self.temperature = temperature
        self.timeRemaining = timeRemaining
        self.notChargingReason = notChargingReason
        self.updatedAt = updatedAt
        self.source = source
    }

    /// Максимальная ёмкость, как её считает iOS: текущая полная ёмкость
    /// относительно проектной, округление до целого, 0…100.
    /// Больше ста не бывает: свежая батарея иногда отдаёт nominal > design,
    /// и «103 %» напугало бы человека без всякой пользы.
    var maximumCapacityPercent: Int {
        guard designCapacity > 0 else { return 0 }
        let value = (Double(nominalCapacity) / Double(designCapacity) * 100).rounded()
        return min(max(Int(value), 0), 100)
    }

    /// Бит «зарядка остановлена, потому что достигнут лимит зарядки iOS».
    ///
    /// Найден на живом телефоне 2026-09-10: без провода и в первые секунды после
    /// втыкания `NotChargingReason` был 128 (0x80), а когда заряд упёрся в лимит
    /// 80 % — стал 16777344 = 0x01000080. Разница ровно в этом бите.
    /// `FullyCharged` в домене `com.apple.mobile.battery` у лимита **не**
    /// взводится, поэтому без него не обойтись.
    static let chargeLimitBit = 0x0100_0000

    /// Телефон стоит у лимита зарядки: провод воткнут, но дальше заряжать iOS не будет.
    var isAtChargeLimit: Bool { (notChargingReason ?? 0) & Self.chargeLimitBit != 0 }
}

import AppKit
import SwiftUI

/// Содержимое `NSPopover` строки меню (план §14.1, §20.1).
///
/// Раскладка: сетка 4 pt, ширина 280 во всех состояниях, паддинг 14 × 12.
/// Отступы задаются `.padding(.bottom, …)` у блоков, а не общим `spacing`,
/// потому что по плану они разные (14 / 8 / 6 / 12 / 10).
struct StatusPopoverView: View {

    @Bindable var monitor: BatteryMonitor
    /// Таблица ARP пришла пустой — почти наверняка не выдано разрешение
    /// «Локальная сеть», и телефон в ней не найти (план §23.2).
    @AppStorage(Prefs.Key.localNetworkBlocked) private var localNetworkBlocked = false
    /// Открыть настройки. Задаёт `StatusItemController`: `SettingsLink` внутри
    /// `NSHostingController` со сценой `Settings` не связан (план §20.1).
    var onSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch monitor.phase {
            case .ready(let status):
                identity
                    .padding(.bottom, 14)
                hero(status)
                    .padding(.bottom, 8)
                gauge(status)
                    .padding(.bottom, 6)
                updatedRow(status)
                    .padding(.bottom, 12)

            case .stale(let status):
                // Телефон спит дольше 15 минут: число остаётся, но честно помечено
                // возрастом, а цвет уходит в secondary — это не текущее состояние (§16.5).
                identity
                    .padding(.bottom, 14)
                staleHero(status)
                    .padding(.bottom, 8)
                gauge(status, stale: true)
                    .padding(.bottom, 6)
                noLinkRow(status)
                    .padding(.bottom, 12)

            case .failed(let error):
                // EmptyStateView собран вручную и меряется по содержимому — фиксированная
                // высота ему больше не нужна (раньше её требовал ContentUnavailableView).
                EmptyStateView(error: error, lastKnown: monitor.lastKnownStatus) {
                    Task { await monitor.refresh(rediscover: true) }
                }
                .padding(.top, 4)
                .padding(.bottom, 14)

            case .idle, .loading:
                loadingBody
                    .padding(.bottom, 12)
            }

            if localNetworkBlocked {
                localNetworkHint
                    .padding(.bottom, 12)
            }

            Divider()
                .padding(.bottom, 10)

            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 280)
        .task { await monitor.refresh(rediscover: false) }
    }

    // MARK: - 1. Идентичность

    private var identity: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(monitor.selectedDevice?.name ?? L("popover.unknownPhone", "iPhone"))
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            deviceSubtitle
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// «iPhone 17 ▏Wi-Fi» одной строкой: модель и транспорт через волосок-разделитель.
    @ViewBuilder
    private var deviceSubtitle: some View {
        let model = monitor.selectedDevice?.modelName
        let transport = monitor.selectedDevice?.transport.displayName
        if model != nil || transport != nil {
            HStack(spacing: 4) {
                if let model { Text(model) }
                if model != nil, transport != nil { Hairline() }
                if let transport { Text(transport) }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    // MARK: - 2. Герой: процент и состояние на одной базовой линии

    private func hero(_ status: BatteryStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(status.percent)%")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.smooth, value: status.percent)
                .accessibilityLabel(String(format: L("a11y.percent", "Заряд %d процентов"),
                                           status.percent))
            chargeState(status)
        }
    }

    @ViewBuilder
    private func chargeState(_ status: BatteryStatus) -> some View {
        HStack(spacing: 4) {
            if status.fullyCharged {
                Image(systemName: SymbolName.checkmark)
                    .foregroundStyle(.green)
            } else if status.isCharging {
                Image(systemName: SymbolName.bolt)
                    .foregroundStyle(.green)
                    // HIG «SF Symbols»: breathe = текущая активность.
                    .symbolEffect(.breathe, isActive: true)
            } else if status.externalConnected {
                Image(systemName: SymbolName.powerplug)
            }
            Text(chargeStateText(status))
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// Тот же герой, но состояние заменено на «Нет связи»: показывать «Не заряжается»
    /// по данным получасовой давности было бы враньём.
    private func staleHero(_ status: BatteryStatus) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(status.percent)%")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(format: L("a11y.percent", "Заряд %d процентов"),
                                           status.percent))
            HStack(spacing: 4) {
                Image(systemName: SymbolName.asleep)
                Text(L("state.noLink", "Нет связи"))
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    // MARK: - 3. Полоса заряда

    /// `Gauge(.linearCapacity)` на macOS 26 рисует полосу 16 pt — втрое толще, чем нужно
    /// по §14.1 (≤ 6 pt). Нативная замена той же семантики: линейный `ProgressView`, ~5 pt.
    private func gauge(_ status: BatteryStatus, stale: Bool = false) -> some View {
        ProgressView(value: status.fraction, total: 1)
            .progressViewStyle(.linear)
            .controlSize(.small)
            .tint(stale ? Color.secondary : Self.tint(for: status, threshold: monitor.threshold))
            .animation(.smooth, value: status.fraction)
            .accessibilityHidden(true)
    }

    // MARK: - 4. Время обновления

    private func updatedRow(_ status: BatteryStatus) -> some View {
        Text(String(format: L("popover.updatedAt", "Обновлено %@"),
                    Self.timeFormatter.string(from: status.updatedAt)))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// «данные 14:32» — возраст показаний вместо времени последнего успеха.
    private func noLinkRow(_ status: BatteryStatus) -> some View {
        Text(String(format: L("popover.dataAt", "данные %@"),
                    Self.timeFormatter.string(from: status.updatedAt)))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Подсказка про разрешение «Локальная сеть»: без него таблица ARP пуста,
    /// и адрес спящего телефона взять неоткуда.
    private var localNetworkHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("hint.localNetwork",
                   "Разреши доступ к локальной сети в Системных настройках → Конфиденциальность"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("hint.localNetwork.open", "Открыть настройки")) {
                guard let url = URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
                else { return }
                NSWorkspace.shared.open(url)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var loadingBody: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("popover.loading", "Опрашиваю iPhone…"))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }

    // MARK: - 5. Действия — только значки, все одного размера

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await monitor.refresh(rediscover: true) }
            } label: {
                // HIG «Кнопки»: у долгого действия индикатор живёт внутри кнопки,
                // а не превращает её в серую disabled-заглушку.
                if monitor.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: Self.glyphSide, height: Self.glyphSide)
                } else {
                    glyph(SymbolName.refresh)
                }
            }
            .help(L("action.refresh", "Обновить"))
            .accessibilityLabel(L("action.refresh", "Обновить"))

            Button {
                onSettings()
            } label: {
                glyph(SymbolName.settings)
            }
            .help(L("action.settings", "Настройки…"))
            .accessibilityLabel(L("action.settings", "Настройки…"))

            Spacer(minLength: 0)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                glyph(SymbolName.quit)
            }
            .help(L("action.quit", "Выход"))
            .accessibilityLabel(L("action.quit", "Выход"))
        }
        .akbButtonStyle()
        .controlSize(.regular)
    }

    /// Одинаковая площадка под любым значком: кнопки в ряду должны быть равны по размеру.
    private static let glyphSide: CGFloat = 16

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .frame(width: Self.glyphSide, height: Self.glyphSide)
    }

    // MARK: - Мелочи

    private func chargeStateText(_ status: BatteryStatus) -> String {
        if status.fullyCharged { return L("state.full", "Заряжен полностью") }
        if status.isCharging { return L("state.charging", "Заряжается") }
        if status.externalConnected { return L("state.plugged", "Подключён к питанию") }
        return L("state.discharging", "Не заряжается")
    }

    /// Цвет = смысл, три состояния (план §14.1). Жёлтого нет: «предупреждение о среднем
    /// заряде» — не смысл, а украшение, а красный обязан значить ровно одно.
    static func tint(for status: BatteryStatus, threshold: Int) -> Color {
        if status.percent < threshold && !status.isCharging { return .red }
        if status.isCharging || status.fullyCharged { return .green }
        return .primary
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

extension View {
    /// Стекло macOS 26, если доступно. Одно место на всё приложение — легко откатить.
    @ViewBuilder
    func akbButtonStyle() -> some View {
        self.buttonStyle(.glass)
    }
}

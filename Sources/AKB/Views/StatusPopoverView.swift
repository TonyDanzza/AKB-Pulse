import AppKit
import SwiftUI

/// Содержимое `MenuBarExtra` в стиле `.window` (план §5.2).
struct StatusPopoverView: View {

    @Bindable var monitor: BatteryMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch monitor.phase {
            case .ready(let status):
                header
                readyBody(status)
            case .failed(let error):
                EmptyStateView(error: error, lastKnown: monitor.lastKnownStatus) {
                    Task { await monitor.refresh(rediscover: true) }
                }
            case .idle, .loading:
                loadingBody
            }

            Divider()
            actions
        }
        .padding(14)
        .frame(width: 300)
        .task { await monitor.refresh(rediscover: false) }
    }

    // MARK: - Шапка

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(monitor.selectedDevice?.name ?? L("popover.unknownPhone", "iPhone"))
                    .font(.headline)
                    .lineLimit(1)
                if let model = monitor.selectedDevice?.modelName {
                    Text(model)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let transport = monitor.selectedDevice?.transport {
                Label(transport.displayName, systemImage: transport.symbolName)
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Основное состояние

    @ViewBuilder
    private func readyBody(_ status: BatteryStatus) -> some View {
        Text("\(status.percent)%")
            .font(.system(size: 44, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.default, value: status.percent)

        Gauge(value: status.fraction, in: 0...1) {
            EmptyView()
        }
        .gaugeStyle(.accessoryLinearCapacity)
        .tint(Self.tint(for: status))

        HStack(spacing: 6) {
            Text(chargeStateText(status))
            Spacer(minLength: 4)
            Text(String(format: L("popover.updatedAt", "Обновлено %@"),
                        Self.timeFormatter.string(from: status.updatedAt)))
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var loadingBody: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L("popover.loading", "Опрашиваю iPhone…"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 20)
    }

    // MARK: - Кнопки

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await monitor.refresh(rediscover: true) }
            } label: {
                Label(L("action.refresh", "Обновить"), systemImage: SymbolName.refresh)
            }
            .disabled(monitor.isRefreshing)

            SettingsLink {
                Label(L("action.settings", "Настройки…"), systemImage: SymbolName.settings)
            }
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
            })

            Spacer(minLength: 0)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label(L("action.quit", "Выход"), systemImage: SymbolName.quit)
            }
        }
        .labelStyle(.titleAndIcon)
        .akbButtonStyle()
        .controlSize(.regular)
    }

    // MARK: - Мелочи

    private func chargeStateText(_ status: BatteryStatus) -> String {
        if status.fullyCharged { return L("state.full", "Заряжен полностью") }
        if status.isCharging { return L("state.charging", "Заряжается") }
        if status.externalConnected { return L("state.plugged", "Подключён к питанию") }
        return L("state.discharging", "Не заряжается")
    }

    static func tint(for status: BatteryStatus) -> Color {
        switch status.level {
        case .critical, .low: .red
        case .medium: .yellow
        case .high: .green
        }
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

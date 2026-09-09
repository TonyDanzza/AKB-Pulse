import AppKit
import SwiftUI

/// Нативные пустые состояния (план §5.4) на `ContentUnavailableView`.
struct EmptyStateView: View {

    var error: ProviderError
    var lastKnown: BatteryStatus?
    var onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            VStack(alignment: .leading, spacing: 8) {
                Text(descriptionText)
                    .multilineTextAlignment(.leading)
                if error == .toolNotFound {
                    HStack(spacing: 6) {
                        Text(Self.brewCommand)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.brewCommand, forType: .string)
                        } label: {
                            Image(systemName: SymbolName.copy)
                        }
                        .buttonStyle(.borderless)
                        .help(L("empty.copy", "Скопировать команду"))
                    }
                }
                if let lastKnown, error != .toolNotFound {
                    Text(String(format: L("empty.lastKnown", "Последний известный заряд: %1$d%% (%2$@)"),
                                lastKnown.percent,
                                Self.timeFormatter.string(from: lastKnown.updatedAt)))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        } actions: {
            Button(L("empty.retry", "Проверить снова"), systemImage: SymbolName.refresh, action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }

    private static let brewCommand = "brew install libimobiledevice"

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private var symbol: String {
        switch error {
        case .toolNotFound: SymbolName.warning
        case .noDevice, .deviceUnreachable: SymbolName.phoneSlash
        case .parseFailure: SymbolName.resolveQuestion
        case .timeout: SymbolName.resolveClock
        }
    }

    private var title: String {
        switch error {
        case .toolNotFound: L("error.toolNotFound.title", "Нужен libimobiledevice")
        case .noDevice: L("error.noDevice.title", "iPhone не найден")
        case .deviceUnreachable: L("error.deviceUnreachable.title", "iPhone вне сети")
        case .parseFailure: L("error.parseFailure.title", "Непонятный ответ телефона")
        case .timeout: L("error.timeout.title", "Телефон не ответил")
        }
    }

    private var descriptionText: String {
        switch error {
        case .toolNotFound:
            L("error.toolNotFound.description",
              "Приложение читает заряд утилитой ideviceinfo. Установи её через Homebrew:")
        case .noDevice:
            L("error.noDevice.description", """
              1. Подключи iPhone кабелем.
              2. Finder → iPhone → Основные → включи «Показывать этот iPhone, если он подключён к Wi‑Fi».
              3. Нажми «Доверять» на телефоне.
              4. Отключи кабель — Mac и iPhone должны быть в одной сети Wi‑Fi.
              5. Если на Mac или iPhone включён VPN — разреши в нём доступ к локальной сети или выключи его на время поиска.
              """)
        case .deviceUnreachable:
            L("error.deviceUnreachable.description",
              "iPhone не отвечает. Проверь, что он включён, разблокирован и в той же сети Wi‑Fi, что и Mac.")
        case .parseFailure:
            L("error.parseFailure.description",
              "ideviceinfo вернул данные, которые не удалось разобрать. Попробуй ещё раз.")
        case .timeout:
            L("error.timeout.description",
              "Телефон не ответил за 10 секунд. Обычно это значит, что он спит или вне сети.")
        }
    }
}

extension SymbolName {
    static var resolveQuestion: String { resolve("questionmark.circle") }
    static var resolveClock: String { resolve("clock.badge.exclamationmark", "clock") }
}

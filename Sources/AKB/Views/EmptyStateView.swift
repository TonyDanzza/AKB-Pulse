import AppKit
import SwiftUI

/// Пустые состояния popover (план §5.4, §15.1).
///
/// Собрано вручную, а не на `ContentUnavailableView`: тот центрирует себя в доступной
/// высоте и требует заданного `minHeight` (иначе схлопывается в ноль), из-за чего над
/// иконкой оставалось пустого места больше, чем текста. Ручная раскладка — те же
/// нативные элементы, но отступы под контролем: сетка 4 pt, шаги списком по 6 pt.
struct EmptyStateView: View {

    var error: ProviderError
    var lastKnown: BatteryStatus?
    var onRetry: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)

            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)

            details
                .padding(.bottom, 12)

            Button(L("empty.retry", "Проверить снова"), systemImage: SymbolName.refresh, action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Тело: список шагов или абзац

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let steps {
                stepList(steps)
            } else {
                Text(descriptionText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Нумерованный список: номер фиксированной ширины, текст переносится своим блоком.
    private func stepList(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .frame(width: 16, alignment: .trailing)
                    Text(step)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
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

    /// Пошаговая инструкция там, где она есть; иначе `nil` и показывается абзац.
    private var steps: [String]? {
        guard error == .noDevice else { return nil }
        return [
            L("error.noDevice.step1", "Подключи iPhone кабелем."),
            L("error.noDevice.step2",
              "Finder → iPhone → Основные → включи «Показывать этот iPhone, если он подключён к Wi‑Fi»."),
            L("error.noDevice.step3", "Нажми «Доверять» на телефоне."),
            L("error.noDevice.step4", "Отключи кабель — Mac и iPhone должны быть в одной сети Wi‑Fi."),
            L("error.noDevice.step5",
              "Если на Mac или iPhone включён VPN — разреши в нём доступ к локальной сети или выключи его на время поиска.")
        ]
    }

    private var descriptionText: String {
        switch error {
        case .toolNotFound:
            L("error.toolNotFound.description",
              "Приложение читает заряд утилитой ideviceinfo. Установи её через Homebrew:")
        case .noDevice:
            ""
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

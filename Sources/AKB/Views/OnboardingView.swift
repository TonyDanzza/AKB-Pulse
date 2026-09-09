import AppKit
import SwiftUI

/// Окно первого запуска (план §12.3). Обычное окно, не popover.
struct OnboardingView: View {

    var monitor: BatteryMonitor
    var onFinish: () -> Void

    @State private var pollTask: Task<Void, Never>?

    private var foundDevice: PhoneDevice? {
        monitor.devices.first(where: { $0.transport == .wifi }) ?? monitor.devices.first
    }

    private var isReady: Bool {
        monitor.devices.contains(where: { $0.transport == .wifi })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !Self.isInApplicationsFolder {
                Label(L("onboarding.moveToApplications", "Лучше перенести «АКБ» в папку «Программы»."),
                      systemImage: SymbolName.folder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L("onboarding.title", "Добро пожаловать в «АКБ»"))
                    .font(.title2.weight(.semibold))
                Text(L("onboarding.subtitle", "Четыре шага — и заряд iPhone будет в строке меню."))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                step(1, symbol: SymbolName.cable,
                     text: L("onboarding.step1", "Подключи iPhone к Mac кабелем."))
                step(2, symbol: SymbolName.window,
                     text: L("onboarding.step2", "В Finder выбери iPhone → вкладка «Основные» → включи «Показывать этот iPhone, если он подключён к Wi‑Fi».")) {
                    Button(L("onboarding.openFinder", "Открыть Finder")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
                    }
                    .controlSize(.small)
                }
                step(3, symbol: SymbolName.tap,
                     text: L("onboarding.step3", "На iPhone нажми «Доверять»."))
                step(4, symbol: SymbolName.wifi,
                     text: L("onboarding.step4", "Отключи кабель. Mac и iPhone должны быть в одной сети Wi‑Fi."))
            }

            Spacer(minLength: 0)
            Divider()
            statusRow

            HStack {
                Spacer()
                Button(L("onboarding.skip", "Пропустить"), action: onFinish)
                Button(L("onboarding.done", "Готово"), action: onFinish)
                    .keyboardShortcut(.defaultAction)   // на выключенной кнопке не срабатывает
                    .buttonStyle(.borderedProminent)
                    .disabled(!isReady)
            }
        }
        .padding(22)
        .frame(width: 480, height: 470)
        .task { startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: - Шаг

    @ViewBuilder
    private func step(_ number: Int,
                      symbol: String,
                      text: String,
                      @ViewBuilder accessory: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.quaternary))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                accessory()
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Живой статус

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 8) {
            if isReady, let device = foundDevice {
                Image(systemName: SymbolName.checkmark)
                    .foregroundStyle(.green)
                Text(String(format: L("onboarding.found", "Найден: %@"), device.name))
                Hairline()
                Text(device.modelName)
                Hairline()
                Text(device.transport.displayName)
            } else {
                ProgressView().controlSize(.small)
                Text(L("onboarding.searching", "Ищу iPhone…"))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .lineLimit(1)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await monitor.rediscoverDevices()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    static var isInApplicationsFolder: Bool {
        Bundle.main.bundleURL.deletingLastPathComponent().path.hasSuffix("Applications")
    }
}

/// Тонкий вертикальный разделитель вместо точки-разделителя.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .frame(width: 1, height: 11)
            .opacity(0.4)
            .foregroundStyle(.secondary)
    }
}

extension SymbolName {
    static var cable: String { resolve("cable.connector", "cable.connector.horizontal", "bolt.horizontal") }
    static var window: String { resolve("macwindow", "rectangle.on.rectangle") }
    static var tap: String { resolve("hand.tap", "hand.point.up.left") }
    static var wifi: String { resolve("wifi") }
    static var checkmark: String { resolve("checkmark.circle.fill", "checkmark.circle") }
}

/// Держит одно окно онбординга: SwiftUI-сцена `Window` не открывается
/// программно на старте, поэтому окно создаётся вручную через NSHostingController.
@MainActor
final class OnboardingWindowController {

    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    static let hasCompletedKey = "hasCompletedOnboarding"

    static var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: hasCompletedKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasCompletedKey) }
    }

    func showIfNeeded(monitor: BatteryMonitor) {
        guard !Self.hasCompleted else { return }
        show(monitor: monitor)
    }

    func show(monitor: BatteryMonitor) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(
            rootView: OnboardingView(monitor: monitor) { [weak self] in
                Self.hasCompleted = true
                self?.close()
            }
        )
        let window = NSWindow(contentViewController: controller)
        window.title = String(localized: "onboarding.title",
                              defaultValue: "Добро пожаловать в «АКБ»")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close() {
        window?.close()
        window = nil
    }
}

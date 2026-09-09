import AppKit
import SwiftUI

/// Сцена `Settings` (план §5.3). Только стандартные контролы, `Form` в стиле `.grouped`.
struct SettingsView: View {

    @Bindable var monitor: BatteryMonitor

    @AppStorage(Prefs.Key.pollInterval) private var pollInterval = 60
    @AppStorage(Prefs.Key.showPercent) private var showPercent = true
    @AppStorage(Prefs.Key.notifyLowBattery) private var notifyLowBattery = true
    @AppStorage(Prefs.Key.lowThreshold) private var lowThreshold = 30
    @AppStorage(Prefs.Key.repeatEveryTen) private var repeatEveryTen = true
    @AppStorage(Prefs.Key.launchAtLogin) private var launchAtLogin = false

    @State private var toolDirectory = ToolLocator.resolvedDirectory
    @State private var launchError: String?
    @State private var isDiscovering = false

    var body: some View {
        Form {
            phoneSection
            pollSection
            notificationsSection
            systemSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 660)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            toolDirectory = ToolLocator.resolvedDirectory
        }
    }

    // MARK: - Телефон

    @ViewBuilder
    private var phoneSection: some View {
        Section(L("settings.phone", "Телефон")) {
            if monitor.devices.isEmpty {
                Text(L("settings.noDevices",
                       "Ни одного iPhone не найдено. Включи в Finder «Показывать этот iPhone, если он подключён к Wi‑Fi»."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker(L("settings.device", "Устройство"), selection: deviceSelection) {
                    ForEach(monitor.devices) { device in
                        Text(device.pickerTitle).tag(device.udid)
                    }
                }
            }

            HStack {
                Button(L("settings.rediscover", "Обновить список")) {
                    isDiscovering = true
                    Task {
                        await monitor.rediscoverDevices()
                        isDiscovering = false
                    }
                }
                .disabled(isDiscovering)
                if isDiscovering {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var deviceSelection: Binding<String> {
        Binding(
            get: { monitor.selectedDevice?.udid ?? "" },
            set: { udid in
                if let device = monitor.devices.first(where: { $0.udid == udid }) {
                    monitor.select(device)
                }
            }
        )
    }

    // MARK: - Опрос

    @ViewBuilder
    private var pollSection: some View {
        Section(L("settings.poll", "Опрос")) {
            Picker(L("settings.interval", "Интервал"), selection: $pollInterval) {
                ForEach(Prefs.pollIntervals, id: \.self) { seconds in
                    Text(Self.intervalTitle(seconds)).tag(seconds)
                }
            }
            .onChange(of: pollInterval) { monitor.settingsChanged() }

            Toggle(L("settings.showPercent", "Показывать проценты в строке меню"), isOn: $showPercent)
        }
    }

    static func intervalTitle(_ seconds: Int) -> String {
        switch seconds {
        case 30: L("interval.30s", "30 секунд")
        case 60: L("interval.1m", "1 минута")
        case 120: L("interval.2m", "2 минуты")
        default: L("interval.5m", "5 минут")
        }
    }

    // MARK: - Уведомления

    @ViewBuilder
    private var notificationsSection: some View {
        Section(L("settings.notifications", "Уведомления")) {
            Toggle(L("settings.notifyLow", "Уведомлять о низком заряде"), isOn: $notifyLowBattery)
                .onChange(of: notifyLowBattery) { _, isOn in
                    if isOn { NotificationService.shared.requestAuthorizationIfNeeded() }
                    monitor.settingsChanged()
                }

            LabeledContent {
                Slider(value: thresholdBinding, in: 10...50, step: 5)
                    .frame(minWidth: 160)
            } label: {
                Text(String(format: L("settings.threshold", "Порог: %d%%"), lowThreshold))
                    .monospacedDigit()
            }
            .disabled(!notifyLowBattery)

            Toggle(L("settings.repeatEveryTen", "Повторять каждые −10%"), isOn: $repeatEveryTen)
                .onChange(of: repeatEveryTen) { monitor.settingsChanged() }
                .disabled(!notifyLowBattery)
        }
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { Double(lowThreshold) },
            set: { newValue in
                let rounded = Int((newValue / 5).rounded() * 5)
                if rounded != lowThreshold {
                    lowThreshold = rounded
                    monitor.settingsChanged()
                }
            }
        )
    }

    // MARK: - Система

    @ViewBuilder
    private var systemSection: some View {
        Section(L("settings.system", "Система")) {
            Toggle(L("settings.launchAtLogin", "Запускать при входе"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, isOn in
                    launchError = LaunchAtLogin.set(isOn)
                    if launchError != nil { launchAtLogin = LaunchAtLogin.isEnabled }
                }
            if let launchError {
                Text(launchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button(L("settings.showOnboarding", "Показать инструкцию…")) {
                OnboardingWindowController.shared.show(monitor: monitor)
            }

            LabeledContent {
                Button(L("settings.choosePath", "Указать путь…"), systemImage: SymbolName.folder) {
                    chooseToolDirectory()
                }
                .labelStyle(.titleOnly)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("libimobiledevice")
                    Text(toolStatusText)
                        .font(.caption)
                        .foregroundStyle(toolDirectory == nil ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var toolStatusText: String {
        guard let directory = toolDirectory else {
            return L("settings.toolMissing", "не найден")
        }
        if directory.contains("/Contents/Helpers") {
            return L("settings.toolBundled", "встроен в приложение")
        }
        return String(format: L("settings.toolFound", "найден в %@"), directory)
    }

    private func chooseToolDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("settings.choose", "Выбрать")
        panel.message = L("settings.choosePrompt",
                          "Укажи папку, где лежат idevice_id и ideviceinfo")
        if panel.runModal() == .OK, let url = panel.url {
            ToolLocator.customDirectory = url.path
            toolDirectory = ToolLocator.resolvedDirectory
            monitor.settingsChanged()
        }
    }
}

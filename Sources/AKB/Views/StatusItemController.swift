import AppKit
import Observation
import SwiftUI

/// Строка меню на AppKit (план §20.1).
///
/// `MenuBarExtra` с SwiftUI-label перерисовывался не при каждом изменении
/// наблюдаемого состояния: пока окно закрыто, label мог висеть со старой иконкой
/// (молния не появлялась до открытия popover). `NSStatusItem` рисуется вручную,
/// поэтому обновление зависит только от нас: `withObservationTracking` ловит
/// изменение `BatteryMonitor`, а таймер раз в 30 с страхует от пропущенного сигнала.
@MainActor
final class StatusItemController {

    private let monitor: BatteryMonitor
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var lastContent: MenuBarLabelRenderer.Content?
    private var safetyTimer: Timer?

    /// Как часто страховочный таймер сверяет нарисованное с настоящим.
    static let safetyInterval: TimeInterval = 30

    init(monitor: BatteryMonitor) {
        self.monitor = monitor
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    func start() {
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(handleClick)
            // Правый клик делает то же, что левый: отдельного меню у нас нет.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: StatusPopoverView(monitor: monitor, onSettings: { [weak self] in
                self?.openSettings()
            })
        )

        render()
        trackChanges()

        let timer = Timer.scheduledTimer(withTimeInterval: Self.safetyInterval, repeats: true) { _ in
            MainActor.assumeIsolated { self.render() }
        }
        timer.tolerance = 5
        safetyTimer = timer
    }

    func stop() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Обновление иконки

    /// Перезаводится после каждого срабатывания: `withObservationTracking` одноразовый.
    private func trackChanges() {
        withObservationTracking {
            _ = MenuBarLabelRenderer.content(for: monitor)
        } onChange: { [weak self] in
            // onChange приходит ДО применения изменения — читать состояние можно
            // только на следующем витке главного потока.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.render()
                self.trackChanges()
            }
        }
    }

    /// `ImageRenderer` недёшев, поэтому рисуем только при настоящем изменении.
    private func render() {
        let content = MenuBarLabelRenderer.content(for: monitor)
        guard content != lastContent else { return }
        lastContent = content
        statusItem.button?.image = MenuBarLabelRenderer.image(content)
        statusItem.button?.toolTip = content.text
    }

    // MARK: - Popover

    @objc private func handleClick() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // `.task` внутри SwiftUI при повторном показе того же контроллера
        // может не сработать — опрос запускаем сами, на каждое открытие.
        Task { await monitor.refresh(rediscover: true) }
    }

    /// Открыть окно настроек из popover. Ни `SettingsLink`, ни
    /// `NSApp.sendAction(showSettingsWindow:)` из popover'а окно не показывают
    /// (проверено: sendAction возвращает `true`, окно не появляется), поэтому
    /// настройки живут в своём NSWindow — как онбординг.
    private func openSettings() {
        popover.performClose(nil)
        SettingsWindowController.shared.show(monitor: monitor)
    }
}

import AppKit
import SwiftUI

/// Рендер иконки строки меню.
///
/// Картинка собирается через `ImageRenderer` и ставится в `NSStatusItem.button.image`
/// (план §5.1, §20.1). Для обычного состояния `isTemplate = true` — тогда macOS сама красит иконку
/// под светлую/тёмную строку меню. Для «низкий заряд» `isTemplate = false` и явный красный.
@MainActor
enum MenuBarLabelRenderer {

    /// Что рисуем.
    struct Content: Equatable {
        var symbol: String
        var showsBolt: Bool
        var text: String?
        var isRed: Bool
        /// Данные старше 15 минут: показываем, но приглушённо (план §16.5).
        var isDim: Bool = false
    }

    static func content(for monitor: BatteryMonitor) -> Content {
        switch monitor.phase {
        case .ready(let status):
            let low = status.percent < monitor.threshold && !status.isCharging
            return Content(symbol: SymbolName.phone,
                           showsBolt: status.isCharging || status.externalConnected,
                           text: monitor.showPercent ? "\(status.percent)%" : nil,
                           isRed: low)
        case .stale(let status):
            let low = status.percent < monitor.threshold && !status.isCharging
            return Content(symbol: SymbolName.phone,
                           showsBolt: false,
                           text: monitor.showPercent ? "\(status.percent)%" : nil,
                           isRed: low,
                           isDim: true)
        case .failed(.toolNotFound):
            return Content(symbol: SymbolName.warning, showsBolt: false, text: nil, isRed: false)
        case .failed:
            return Content(symbol: SymbolName.phoneSlash, showsBolt: false, text: nil, isRed: false)
        case .idle, .loading:
            return Content(symbol: SymbolName.phone, showsBolt: false, text: nil, isRed: false)
        }
    }

    private static let fontSize: CGFloat = 12
    private static let symbolPointSize: CGFloat = 15

    /// Собирает NSImage для строки меню.
    static func image(_ content: Content) -> NSImage {
        let color: Color = content.isRed ? .red : .black

        let view = HStack(spacing: 2) {
            Image(systemName: content.symbol)
                .font(.system(size: symbolPointSize, weight: .regular))
            if content.showsBolt {
                Image(systemName: SymbolName.bolt)
                    .font(.system(size: 8, weight: .bold))
            }
            if let text = content.text {
                Text(text)
                    .font(.system(size: fontSize, weight: .regular).monospacedDigit())
            }
        }
        .foregroundStyle(color)
        .opacity(content.isDim ? 0.55 : 1)
        .padding(.horizontal, 1)
        .fixedSize()

        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2

        guard let cgImage = renderer.cgImage else {
            return NSImage(systemSymbolName: content.symbol, accessibilityDescription: nil)
                ?? NSImage()
        }

        let scale = renderer.scale
        let size = NSSize(width: CGFloat(cgImage.width) / scale,
                          height: CGFloat(cgImage.height) / scale)
        let image = NSImage(cgImage: cgImage, size: size)
        image.isTemplate = !content.isRed
        image.accessibilityDescription = content.text ?? "AKB Pulse"
        return image
    }
}

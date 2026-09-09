// Кликает по элементу строки меню и, по желанию, по точке внутри popover.
// Нужен, чтобы снимать popover и настройки без рук (план §19.3, §14.4).
//
//   swift scripts/dev/click-menubar.swift            — открыть popover
//   swift scripts/dev/click-menubar.swift 1180 320   — открыть и кликнуть в точку
//
// Требуется разрешение «Универсальный доступ» для терминала.
import AppKit

func click(_ point: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(120_000)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(60_000)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

let args = CommandLine.arguments.dropFirst().compactMap(Double.init)

// Элемент «АКБ» ищем по строке меню приложения через Accessibility.
guard let akb = NSWorkspace.shared.runningApplications
    .first(where: { $0.bundleIdentifier == "ru.tonydanzza.akb" }) else {
    FileHandle.standardError.write(Data("АКБ не запущен\n".utf8))
    exit(1)
}

let app = AXUIElementCreateApplication(akb.processIdentifier)
var barValue: CFTypeRef?
AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &barValue)
var children: CFTypeRef?
if let bar = barValue {
    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
}
guard let items = children as? [AXUIElement], let item = items.first else {
    FileHandle.standardError.write(Data("не нашёл элемент строки меню\n".utf8))
    exit(2)
}

var positionValue: CFTypeRef?
var sizeValue: CFTypeRef?
AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &positionValue)
AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeValue)
var origin = CGPoint.zero
var size = CGSize.zero
AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
print("элемент строки меню: \(Int(center.x)), \(Int(center.y))")
click(center)

if args.count >= 2 {
    usleep(700_000)
    click(CGPoint(x: args[0], y: args[1]))
}

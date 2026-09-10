// Кликает по элементу строки меню и, по желанию, по точке внутри popover.
// Нужен, чтобы снимать popover и настройки без рук (план §19.3, §14.4).
//
//   swift scripts/dev/click-menubar.swift                  — открыть popover
//   swift scripts/dev/click-menubar.swift 1180 320         — открыть и кликнуть в точку
//   swift scripts/dev/click-menubar.swift --pid 1234       — выбрать процесс явно
//   AKB_PID=1234 swift scripts/dev/click-menubar.swift     — то же через окружение
//
// Когда рядом с отладочной сборкой работает копия из /Applications, процессов
// с одним bundle id несколько. Гадать нельзя: скрипт печатает список в stderr
// и выходит с кодом 3 — выбирайте нужный через --pid.
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

/// Время запуска процесса. У копии, поднятой не через Launch Services
/// (например, бинарником из Terminal), `launchDate` пуст — тогда спрашиваем ядро.
func startDate(of app: NSRunningApplication) -> Date? {
    if let date = app.launchDate { return date }
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, app.processIdentifier]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let started = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000)
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

// MARK: - Разбор аргументов

var rest = Array(CommandLine.arguments.dropFirst())
var wantedPID: pid_t?

if let flag = rest.firstIndex(of: "--pid") {
    guard flag + 1 < rest.count, let value = pid_t(rest[flag + 1]) else {
        fail("после --pid нужен номер процесса", code: 1)
    }
    wantedPID = value
    rest.removeSubrange(flag...(flag + 1))
} else if let env = ProcessInfo.processInfo.environment["AKB_PID"], !env.isEmpty {
    guard let value = pid_t(env) else { fail("AKB_PID=\(env) — не номер процесса", code: 1) }
    wantedPID = value
}

let args = rest.compactMap(Double.init)

// MARK: - Выбор процесса

let candidates = NSWorkspace.shared.runningApplications
    .filter { $0.bundleIdentifier == "ru.tonydanzza.akb" }

let akb: NSRunningApplication
if let wantedPID {
    guard let match = candidates.first(where: { $0.processIdentifier == wantedPID }) else {
        fail("процесса AKB Pulse с pid \(wantedPID) нет", code: 1)
    }
    akb = match
} else if candidates.isEmpty {
    fail("AKB Pulse не запущен", code: 1)
} else if candidates.count > 1 {
    // Элемент строки меню у каждой копии свой; выбирать за пользователя нельзя.
    let stamp = DateFormatter()
    stamp.dateFormat = "HH:mm:ss"
    var lines = ["запущено несколько копий AKB Pulse — укажите нужную через --pid:"]
    for app in candidates.sorted(by: { $0.processIdentifier < $1.processIdentifier }) {
        let path = app.bundleURL?.path ?? "путь неизвестен"
        let started = startDate(of: app).map(stamp.string(from:)) ?? "время неизвестно"
        lines.append("\(app.processIdentifier)  \(path)  \(started)")
    }
    fail(lines.joined(separator: "\n"), code: 3)
} else {
    akb = candidates[0]
}

// MARK: - Элемент строки меню

// Элемент «AKB Pulse» ищем по строке меню приложения через Accessibility.
let app = AXUIElementCreateApplication(akb.processIdentifier)
var barValue: CFTypeRef?
AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &barValue)
var children: CFTypeRef?
if let bar = barValue {
    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children)
}
guard let items = children as? [AXUIElement], let item = items.first else {
    fail("не нашёл элемент строки меню", code: 2)
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
print("элемент строки меню: \(Int(center.x)), \(Int(center.y)) (pid \(akb.processIdentifier))")
click(center)

if args.count >= 2 {
    usleep(700_000)
    click(CGPoint(x: args[0], y: args[1]))
}

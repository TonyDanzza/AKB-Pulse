# План: починить всё, что нашёл раунд 2 тестов

Источник: `TESTS-REPORT.md` (пункты 1–11, 13). Пункты 12 и 14 — не баги, не трогать.
Автор плана: Fable. Исполнитель: Opus. Проверка: Fable. Не коммитить, DMG не собирать, версию не менять.

Общие правила: правки минимальные, стиль и комментарии — как в проекте (по-русски, с
отсылкой к «план §…» где уместно). На каждую правку, которую можно проверить тестом, —
тест. После всего: `xcodegen generate`, полный `xcodebuild … test` зелёный, `xcodebuild … build`
без предупреждений в наших файлах. Отчёт — `FIX-REPORT.md` (таблица: пункт → файл:строки → что
сделано → каким тестом покрыто).

## 1. ProcessRunner: добивать SIGKILL — `Sources/AKB/Services/ProcessRunner.swift`
После `process.terminate()`: `finished.wait(timeout: .now() + 1)`; если `.timedOut` —
`kill(process.processIdentifier, SIGKILL)` и ещё `finished.wait(.now() + 2)`. Затем `readers.wait`
как было. Тест в `ProcessRunnerTests`: `sh -c "trap '' TERM; exec sleep 30"` (SIG_IGN переживает
exec, так что sleep игнорирует SIGTERM) с таймаутом 0.3 → бросает `.timeout`, весь вызов
укладывается в 3 с.

## 2. ARPTable.parseRouteDump: границы — `Sources/AKB/Services/ARPTable.swift`
Не грузить `sockaddr`/`sockaddr_in`/`sockaddr_dl` через `loadUnaligned` целиком. Читать байтами:
- нужно `cursor + 2 <= offset + length`, иначе `break`; `saLen = Int(raw[cursor])`, `family = raw[cursor+1]`;
- нужно `cursor + saLen <= offset + length` (при `saLen == 0` — тоже `break`);
- bit 0, AF_INET: IP из `raw[cursor+4 ..< cursor+8]`, только если `saLen >= 8`;
- bit 1, AF_LINK: `nlen = raw[cursor+5]`, `alen = raw[cursor+6]` только если `saLen >= 8`;
  MAC из `macOffset = cursor + 8 + nlen`, только если `alen == 6` и `macOffset + 6 <= offset + length`;
- `cursor += roundup(saLen)`.
`ipv4String(in_addr)` можно заменить на сборку строки из четырёх байт.
Тесты в `RouteDumpTests` (там уже есть сборщики `inet`/`link`/`message`): (а) последнее сообщение
буфера кончается коротким `sockaddr_dl` длиной 8 (nlen 0, alen 0) — не падает, таблица пуста;
(б) сообщение обрезано так, что `sockaddr_dl` заявляет alen 6, но MAC-байты лежат уже за
`rtm_msglen` — MAC не берётся из соседней записи (сделать вторую запись с другим MAC сразу
следом и проверить, что первой записи в таблице нет). Все существующие `RouteDumpTests` и
`ARPTableTests` остаются зелёными.

## 3. Ложная подсказка «Локальная сеть» без сети — `Sources/AKB/Services/DeviceAddressResolver.swift`
Новый файл `Sources/AKB/Services/NetworkInterfaces.swift`: `enum NetworkInterfaces { static func hasActiveIPv4() -> Bool }`
через `getifaddrs`: есть интерфейс не `lo*`, с флагами `IFF_UP | IFF_RUNNING`, семейство `AF_INET`.
В `DeviceAddressResolver.init` добавить параметр `hasNetwork: @escaping @Sendable () -> Bool = { NetworkInterfaces.hasActiveIPv4() }`.
В `addressFromARP`, когда обе таблицы пусты: `Prefs.localNetworkBlocked = hasNetwork()`; лог —
разный текст для «сети нет» и «похоже, нет разрешения». Тесты: в `DeviceAddressResolverEdgeTests`
добавить в `make(...)` параметр `hasNetwork` (по умолчанию `{ true }`), тест: сети нет → флаг
остаётся `false`, результат `nil`. Существующий `localNetworkHint` в `DeviceAddressResolverTests`
— передать `hasNetwork: { true }` в его `makeResolver`, чтобы не зависеть от машины.
Тест на `NetworkInterfaces.hasActiveIPv4()` — только «не падает и возвращает Bool».

## 4. Повторное уведомление после смены настроек — `AlertPolicy.swift`, `BatteryMonitor.swift`
В `AlertPolicy` добавить `func reconfigured(threshold: Int, repeatEveryTenPercent: Bool) -> AlertPolicy`:
если `threshold` тот же — новая политика с тем же `lastFiredStep`; если порог другой — `lastFiredStep = nil`.
В `BatteryMonitor.settingsChanged()` и в `evaluateAlert` заменить создание `AlertPolicy(...)` на
`policy.reconfigured(...)`. `select(_:)` по-прежнему делает `reset()`. Тесты в `AlertPolicyEdgeTests`:
заменить `newPolicyReArms` на два теста — (а) тот же порог, сменили повтор: 25% после
уведомления не даёт второго; (б) другой порог: взводится заново.

## 5. Хвост пайпа при смерти помощника — `DeviceEventWatcher.swift`, `runOnce()`
После завершения процесса: `readabilityHandler = nil`, затем
`let rest = output.fileHandleForReading.readDataToEndOfFile()` и, если не пусто,
прогнать через тот же `LineBuffer` и `handle(_:)` для каждой строки. Процесс уже мёртв,
EOF гарантирован. Теста нет (метод private); описать в отчёте.

## 6. Выбор запомненного телефона — `IMobileDeviceProvider.swift`, `BatteryMonitor.swift`
`BatteryMonitor.pick(from:preferredUDID:)` пометить `nonisolated static` (функция чистая).
`cachedDevice()` сделать internal и переписать: собрать `Prefs.cachedDevice(udid:)` для всех
ключей `Prefs.deviceNames` (отсортированных для стабильности), вернуть
`BatteryMonitor.pick(from: all, preferredUDID: Prefs.selectedUDID)`. Тест в `PrefsTests`
(suite `.serialized`): запомнить два телефона — `iPhone15,4` с UDID «A…» и `iPhone18,3` с UDID
«B…», `selectedUDID` пуст → `IMobileDeviceProvider().cachedDevice()?.productType == "iPhone18,3"`;
с `selectedUDID = A` → A. Убрать за собой (deviceNames/productTypes/selectedUDID).
Проверить, что `ProductTypeMapTests.devicePicking` (он `@MainActor`) по-прежнему компилируется.

## 7. Сильный захват в страховочном таймере — `Views/StatusItemController.swift:49–53`
`Timer.scheduledTimer(...) { [weak self] _ in MainActor.assumeIsolated { self?.render() } }`.

## 8. Порог и «показывать проценты» — `Views/StatusItemController.swift`
В `start()` подписаться на `UserDefaults.didChangeNotification` (`NotificationCenter.default`,
`queue: .main`, `[weak self]`, `MainActor.assumeIsolated { self?.render() }`); хранить observer,
снимать в `stop()`. `render()` и так сравнивает `content` с `lastContent`, лишних перерисовок не будет.

## 9. Пустое имя хоста — `DeviceAddressResolver.swift`, `learnHostname`
`guard (cache.hostname(for: udid) ?? "").isEmpty else { return }`. Тест в
`DeviceAddressResolverEdgeTests`: `StubCache(hostname: "")`, `StubNames(reverse: [ip: name])`,
`confirm` → имя выучено, `reverseCalls == 1`.

## 10. akb-direct watch и EINTR — `Helpers/akb-direct/akb-direct.c:230`
```c
for (;;) {
    n = read(STDIN_FILENO, buffer, sizeof(buffer));
    if (n > 0) continue;
    if (n < 0 && errno == EINTR) continue;
    break;
}
```
`#include <errno.h>`.

## 11. Утечки в mode_battery — `akb-direct.c:70–116`
Освобождать на всех путях: `dev->udid`, `dev`, `sa` (`sa` лежит в `dev->conn_data`, освобождать
один раз). Порядок: сначала `lockdownd_client_free(client)` (клиент держит `idevice_t`), потом
`free(dev->udid); free(dev->conn_data); free(dev);`. Удобно — общая метка `out:` с кодом возврата.
Сборка помощника входит в `xcodebuild … build` (target `akb-direct`) — предупреждений быть не должно.

## 13. BonjourHostname: владение объектом — `Services/BonjourHostname.swift`
В `start`: `let context = Unmanaged.passRetained(self).toOpaque()` — объект живёт, пока dnssd
может позвать обратно. В `finish` (он выполняется ровно один раз — гарантия `guard let pending`):
после `queue.async { … Deallocate … }` вызвать `Unmanaged.passUnretained(self).release()`.
Замыкание `queue.async` держит `self` сильно, поэтому dealloc-вызовы безопасны. В `found()`
контекст для `DNSServiceResolve` оставить `passUnretained` (это тот же объект, второй retain не нужен).
Комментарий обновить. Тестов нет (нужна сеть); проверить чтением, что нет двойного release.

## Финал
1. `xcodegen generate`; `xcodebuild -project AKB.xcodeproj -scheme AKB -configuration Debug -derivedDataPath build test -destination 'platform=macOS' 2>&1 | tee build/test-round3.log | grep -E "error:|warning:.*(Sources|Tests|Helpers)/|Test run with|TEST (SUCCEEDED|FAILED)"`.
2. `xcodebuild … build 2>&1 | tee build/build-round3.log | grep -E "error:|warning:.*(Sources|Helpers)/|BUILD"`.
3. Запустить приложение в фейковом режиме на 15 с и убедиться, что оно не падает:
   `AKB_FAKE_PERCENT=25 build/Build/Products/Debug/AKB.app/Contents/MacOS/AKB & sleep 15; kill %1`
   (файл `/Users/tonydanzza/Library/Logs/AKB/akb.log` не должен содержать «crash»; достаточно, что процесс жил 15 с).
4. `FIX-REPORT.md`.

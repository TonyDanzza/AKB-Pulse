# Отчёт: правки по FIX-PLAN.md

План: `FIX-PLAN.md` (пункты 1–11, 13 и раздел «Финал»). Автор плана — Fable, исполнитель — Opus.
Машина: macOS 26 (Darwin 27), схема `AKB`, конфигурация Debug.

## Итог

| | Тестов | Наборов | Прошло | Упало |
|---|---|---|---|---|
| До правок (раунд 2) | 205 | 30 | 205 | 0 |
| После правок | 213 | 31 | 213 | 0 |

* `xcodegen generate` — проект пересобран, новый файл `NetworkInterfaces.swift` подхватился сам;
* `xcodebuild … test -destination 'platform=macOS'` → **TEST SUCCEEDED**, лог `build/test-round3.log`;
* `xcodebuild … build` → **BUILD SUCCEEDED**, лог `build/build-round3.log`;
* предупреждений в `Sources/`, `Tests/`, `Helpers/` — ноль в обоих логах (проверено грепом по `warning:`);
* набор прогнан четыре раза подряд, все четыре зелёные, 2,81–2,88 с. Плавающих падений нет;
* приложение в фейковом режиме (`AKB_FAKE_PERCENT=25`) прожило 47 с и было остановлено вручную;
  в `~/Library/Logs/AKB/akb.log` за это время ни одной строки со словом «crash»,
  отчётов в `~/Library/Logs/DiagnosticReports` не появилось.

Ни одного существующего теста не удалено и не ослаблено. Ни один существующий тест
после правок не упал. Коммитов нет, DMG не собирался, `project.yml` и версия не тронуты.

## Что сделано

| № | Файл : строки | Что сделано | Каким тестом покрыто |
|---|---|---|---|
| 1 | `Sources/AKB/Services/ProcessRunner.swift:74–86` | После `terminate()` ждём 1 с; если процесс жив — `kill(pid, SIGKILL)` и ещё 2 с. Только потом `readers.wait` и `.timeout`, как было | `ProcessRunnerTests.ignoredTermGetsKilled` (новый, `ProcessRunnerTests.swift:36–45`): `sh -c "trap '' TERM; exec sleep 30"` с таймаутом 0,3 с бросает `.timeout` и укладывается в 3 с |
| 2 | `Sources/AKB/Services/ARPTable.swift:114–142`, удалён `ipv4String` | Адреса разбираются побайтно, без `loadUnaligned` целых `sockaddr`/`sockaddr_in`/`sockaddr_dl`. Границы: `cursor + 2 <= limit`, `saLen > 0`, `cursor + saLen <= limit`; IP только при `saLen >= 8`; MAC только при `alen == 6` и `macOffset + 6 <= limit`, где `limit` — конец текущего сообщения, а не всего буфера | `RouteDumpTests.shortLinkAtBufferEnd` и `RouteDumpTests.macNotStolenFromNextMessage` (новые, `RouteDumpTests.swift:135–152`) + все девять прежних `RouteDumpTests` и `ARPTableTests` |
| 3 | новый `Sources/AKB/Services/NetworkInterfaces.swift`; `DeviceAddressResolver.swift:88–90, 101, 108, 221–233` | `NetworkInterfaces.hasActiveIPv4()` через `getifaddrs`: не `lo*`, `IFF_UP` и `IFF_RUNNING`, `AF_INET`. У резолвера новый параметр `hasNetwork` (по умолчанию — эта функция). При двух пустых таблицах `Prefs.localNetworkBlocked = hasNetwork()`, текст в логе разный для «сети нет» и «похоже, нет разрешения» | `DeviceAddressResolverEdgeTests.noNetworkNoHint` (новый, стр. 292–303), `NetworkInterfacesTests.doesNotCrash` (новый, `NetworkHelpersTests.swift:100–109`); существующий `localNetworkHint` получил `hasNetwork: { true }` и больше не зависит от машины |
| 4 | `Sources/AKB/Services/AlertPolicy.swift:58–65`; `BatteryMonitor.swift:234–239, 377–382` | `AlertPolicy.reconfigured(threshold:repeatEveryTenPercent:)`: тот же порог — `lastFiredStep` переносится, другой — сбрасывается. `settingsChanged()` и `evaluateAlert` пересоздают политику через него; `select(_:)` по-прежнему делает полный `reset()` | `AlertPolicyEdgeTests.reconfiguredKeepsStep` и `.reconfiguredReArmsOnNewThreshold` (заменили `newPolicyReArms`, стр. 80–96) |
| 5 | `Sources/AKB/Services/DeviceEventWatcher.swift:99–105` | После смерти процесса: `readabilityHandler = nil`, затем `readDataToEndOfFile()` и прогон хвоста через тот же `LineBuffer` и `handle(_:)` | Теста нет: `runOnce()` приватный. Проверено отдельным скриптом (см. ниже) |
| 6 | `Sources/AKB/Services/IMobileDeviceProvider.swift:86–92`; `BatteryMonitor.swift:367` | `cachedDevice()` стал `internal` и собирает `PhoneDevice` по всем ключам `Prefs.deviceNames` (отсортированным), а выбор отдаёт `BatteryMonitor.pick(from:preferredUDID:)`. Сама `pick` помечена `nonisolated static` | `PrefsTests.cachedDevicePicksIPhone17Family` (новый, стр. 86–105). `ProductTypeMapTests.devicePicking` (`@MainActor`) компилируется и проходит |
| 7 | `Sources/AKB/Views/StatusItemController.swift:53–55` | Страховочный таймер захватывает `self` слабо: `[weak self] _ in MainActor.assumeIsolated { self?.render() }` | Теста нет: `Views/` не входит в цель тестов (`project.yml`, `AKBTests`) |
| 8 | `Sources/AKB/Views/StatusItemController.swift:20–23, 59–66, 69–77` | В `start()` подписка на `UserDefaults.didChangeNotification` (`NotificationCenter.default`, `queue: .main`, `[weak self]`), наблюдатель хранится в `defaultsObserver` и снимается в `stop()` | Теста нет, причина та же |
| 9 | `Sources/AKB/Services/DeviceAddressResolver.swift:302–304` | `learnHostname` выходит только при непустом имени: `guard (cache.hostname(for: udid) ?? "").isEmpty else { return }` | `DeviceAddressResolverEdgeTests.emptyHostnameRelearned` (новый, стр. 305–311) |
| 10 | `Helpers/akb-direct/akb-direct.c:20, 239–246` | `#include <errno.h>`; цикл ожидания EOF на stdin переписан на `for (;;)` с `continue` при `n < 0 && errno == EINTR` | Теста нет (C-помощник без тестовой обвязки). Собирается без предупреждений |
| 11 | `Helpers/akb-direct/akb-direct.c:71–126` | Общая метка `out:` и код возврата в `rc`. На всех путях освобождаются `it`, `val`, `client`, `dev->udid`, `dev->conn_data` (это и есть `sa`, освобождается один раз) и `dev`. `lockdownd_client_free` идёт первым: клиент держит `idevice_t` | Теста нет. Собирается без предупреждений |
| 13 | `Sources/AKB/Services/BonjourHostname.swift:44–46, 61–62, 81–83` | В `start` контекст dnssd — `Unmanaged.passRetained(self)`. В `finish` (выполняется ровно один раз благодаря `guard let pending`) после `queue.async { … Deallocate … }` идёт `Unmanaged.passUnretained(self).release()`. В `found()` контекст остался `passUnretained` | Теста нет (нужна настоящая сеть). Проверено чтением, см. ниже |

## Проверки сверх тестов

**Пункт 2 — новые тесты действительно ловят старую ошибку.** Отдельным скриптом
прогнал прежнюю реализацию `parseRouteDump` по новым фикстурам:

* `shortLinkAtBufferEnd` — старый код падает: `Fatal error: UnsafeRawBufferPointer.load out of bounds`
  (то самое чтение 20 байт `sockaddr_dl` при проверке границы по 16 байтам `sockaddr`);
* `macNotStolenFromNextMessage` — старый код выдаёт `["01:02:03:04:05:06": "192.168.1.1",
  "34:10:be:d8:21:80": "192.168.1.11"]`: последний байт MAC подобран из заголовка
  следующего сообщения. Новый код такую запись просто пропускает.

**Пункт 5 — хвост пайпа читается и не вешает поток.** Скриптом воспроизвёл схему
`runOnce()`: помощник печатает две строки и сразу умирает, `readabilityHandler`
намеренно ничего не читает, затем снимается и вызывается `readDataToEndOfFile()`.
Вызов вернулся мгновенно (сторож на 5 с не сработал) и отдал обе строки —
`["ADD UDID network", "REMOVE UDID"]`. То есть Foundation закрывает родительский
конец записи при запуске, EOF после смерти процесса гарантирован, зависания нет.

**Пункт 13 — двойного release нет.** `finish` защищён `guard let pending = continuation`
и обнуляет `continuation` до всего остального, поэтому тело выполняется ровно один раз
на объект, и `release()` в нём тоже один. Все три пути в `finish` (ошибка `DNSServiceBrowse`,
будильник `asyncAfter`, ответ `resolveReply`) идут по одной и той же очереди `queue`,
на которой сидят и обратные вызовы dnssd, так что вложенный `queue.async` с
`DNSServiceRefDeallocate` исполняется строго позже и держит `self` сильно —
после `release()` объект жив до самого закрытия запросов. `passRetained` берётся
один раз, в `start`, до любой ветки, которая может позвать `finish`.

## Где отступил от плана

1. **Пункт 2, тест (а).** План описывает «короткий `sockaddr_dl` длиной 8» в конце буфера.
   Буквально так ошибка не воспроизводится: при `sa_len = 8` уже старая проверка
   `cursor + 16 <= offset + length` не пропускала чтение, и падения не было.
   Чтобы тест бил в настоящую ошибку, `sockaddr_dl` в фикстуре **объявляет** длину 8
   (`nlen` и `alen` нулевые), но занимает последние 16 байт сообщения — именно так
   старая проверка проходит, а `loadUnaligned(as: sockaddr_dl.self)` уходит на 4 байта
   за конец буфера. Падение старой реализации на этой фикстуре подтверждено (см. выше).

2. **Пункт 2, тест (б).** По той же причине обрезка сделана не «MAC-байты за `rtm_msglen`
   при полностью коротком адресе», а так: первому сообщению отдано ровно 16 байт под
   `sockaddr_dl`, который объявляет длину 20 и `alen 6`. Старая проверка (16 байт) проходит,
   `macOffset + 6 <= raw.count` тоже — и MAC собирается частично из следующей записи.
   Проверка в тесте, как и просил план: первой записи в таблице нет.

3. **Пункт 3, текст лога.** «Сети нет» пишется строкой
   `таблица ARP пуста, но и сети нет ни на одном интерфейсе` — формулировка моя,
   план задавал только требование «разный текст».

4. **Пункт 11, порядок освобождения.** План перечисляет `client`, затем `dev`.
   Добавил к этому освобождение `it` и `val` на пути ошибки `get_value` (раньше они
   терялись при раннем выходе только частично) — иначе общая метка `out:` их бы обошла.
   Плана это не нарушает, но в нём такого пункта не было.

5. **Пункт 4, `evaluateAlert`.** План говорит заменить создание `AlertPolicy` на
   `policy.reconfigured(...)` и в `settingsChanged()`, и в `evaluateAlert`. Сделал в обоих,
   но стоит отметить следствие: в `evaluateAlert` ветка срабатывает только при расхождении
   с `Prefs`, и при смене одного лишь `repeatEveryTen` взвод теперь тоже сохраняется.
   Это ровно то поведение, которого просит §4.

## Что не удалось

Ничего из пунктов 1–11 и 13 не осталось несделанным. Без тестов остались, как и
предполагал план, пункты 5, 7, 8, 10, 11 и 13; для 5 и 13 проверка описана выше,
7 и 8 недоступны тестам структурно (цель `AKBTests` собирает только `Model` и `Services`),
10 и 11 — код на C без тестовой обвязки в проекте.

## Замеченное попутно (не исправлялось)

1. **`Prefs.localNetworkBlocked` — общее состояние в параллельных тестах.**
   Существующий `DeviceAddressResolverTests.localNetworkHint` ставит флаг в `true`,
   новый `DeviceAddressResolverEdgeTests.noNetworkNoHint` проверяет, что он остался `false`.
   Наборы Swift Testing идут параллельно, так что теоретически они могут пересечься.
   За четыре полных прогона ни разу не пересеклись, и риск этот не новый — он был у
   `localNetworkHint` и раньше. Если однажды всплывёт плавающее падение, лечится
   переносом обоих тестов в один `.serialized`-набор или подстановкой кэша вместо `Prefs`.

2. **Тесты пишут в настоящие `UserDefaults`.** `PrefsTests` работают с реальным доменом
   (`cachedDevicePicksIPhone17Family` на время теста подменяет `deviceNames`,
   `deviceProductTypes` и `selectedUDID`, а в `defer` возвращает всё как было).
   Пока цель тестов идёт без host-приложения, домен у неё свой, и настройки
   установленного `/Applications/AKB.app` не задеваются, но связь эта неявная.

3. **Во время финального прогона на машине работали два экземпляра АКБ** — мой фейковый
   из `build/` и установленный `/Applications/AKB.app`. Оба пишут в один и тот же
   `~/Library/Logs/AKB/akb.log`, строки перемешиваются, и разобрать, чей это опрос,
   можно только по заголовку запуска. Для отладки это неудобно; на работу не влияет.
   Установленный экземпляр я не трогал.

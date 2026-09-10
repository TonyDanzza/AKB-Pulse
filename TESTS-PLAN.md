# План: прогон новых тестов и поиск ошибок (раунд 2)

Автор плана и тестов: Fable. Исполнитель: Opus. Проверка: Fable.

## Что сделано до тебя

В `Tests/AKBTests/` добавлено 12 файлов с ~135 новыми тестами (было 70):

| Файл | Что проверяет |
|---|---|
| `ModelTests.swift` | BatteryStatus (границы уровней, зажим), PhoneDevice Codable, ProviderError, FakeProvider (sleep/toggle) |
| `AlertPolicyEdgeTests.swift` | порог 0/100/нечётный, резкое падение, колебания, восстановленное состояние |
| `RetryWindowEdgeTests.swift` | отмена во сне, шаг после открытого порта, нулевое окно, чужие ошибки |
| `RouteDumpTests.swift` | синтетический дамп `rt_msghdr` + `sockaddr_in` + `sockaddr_dl` для `ARPTable.parseRouteDump` |
| `ParserEdgeTests.swift` | пробелы/табы, формы чисел, дубли ключей, фильтр UDID |
| `ProcessRunnerTests.swift` | настоящие процессы: stdout/stderr/код, большой вывод, таймаут, параллельность |
| `NetworkHelpersTests.swift` | PortProbe на живом loopback-сокете, SystemHostnameResolver (localhost), ToolLocator |
| `FileLogEdgeTests.swift` | незаписываемый каталог, keep=1, порядок файлов, AKBLog сохраняет порядок строк, SupportReport края |
| `LineBufferTests.swift` | склейка порций вывода `akb-direct watch` |
| `PrefsTests.swift` | remember/cachedDevice, удаление пустых словарей, PrefsAddressCache |
| `DeviceAddressResolverEdgeTests.swift` | мусор в кэше, IPv6 от mDNS, часы забвения адреса (6 ч), throttle Bonjour, ping перед arp, замена адреса |
| `BatteryMonitorTests.swift` | интеграция BatteryMonitor с провайдером по сценарию: осечки, stale/failed, сброс счётчика, выбор телефона, isLow, параллельный refresh, границы nextPhase |

## Шаги

1. **Видимость `LineBuffer`.** В `Sources/AKB/Services/DeviceEventWatcher.swift` класс
   `private final class LineBuffer` сделать `final class LineBuffer` (internal). Больше в
   исходниках ради компиляции тестов ничего не менять.
2. `xcodegen generate` (проект в .gitignore, новые файлы тестов подхватятся).
3. Собрать и прогнать:
   ```bash
   cd /Users/tonydanzza/Documents/AKB
   xcodegen generate
   xcodebuild -project AKB.xcodeproj -scheme AKB -configuration Debug \
       -derivedDataPath build test -destination 'platform=macOS' 2>&1 | tee build/test-round2.log \
       | grep -E "error:|warning: .*Tests/|Test .* (passed|failed)|Suite .* (passed|failed)|Executed|TEST (SUCCEEDED|FAILED)"
   ```
   Полный лог оставить в `build/test-round2.log`.
4. **Ошибки компиляции тестов** — чинить в тестах (это Swift 6, strict concurrency: возможны
   мелкие промахи Fable с изоляцией/`await`). Смысл теста не менять. Каждую правку записать в отчёт.
5. **Упавшие тесты.** Для каждого решить: (а) ошибка в коде приложения, (б) ошибка в
   ожидании теста, (в) тест зависит от окружения (сеть/DNS). Правило:
   - (а) — чинить код минимальной правкой, тест не трогать. Если правка меняет поведение,
     описанное в README/PLAN.md, — не чинить, а записать в отчёт как вопрос.
   - (б) — исправить тест и объяснить в отчёте, почему ожидание было неверным.
   - (в) — отметить в отчёте; если тест нестабилен, ослабить проверку, но не удалять.
   - Тест `rediscoverFailureKeepsFreshReading` — заранее известный кандидат на баг №1 (ниже).
     Не переписывать ожидание, пока не разобрался, какое поведение правильное.
6. **Поиск ошибок чтением кода** (независимо от тестов). Пройти файлы в `Sources/AKB/Services/`
   и `Sources/AKB/Views/StatusItemController.swift`, `Views/MenuBarLabel.swift`,
   `Helpers/akb-direct/akb-direct.c`. Что искать: гонки на `@MainActor`, утечки `Task`/observer,
   неверные границы (`<` vs `<=`), поведение при пустых/мусорных данных, не закрытые
   файловые дескрипторы/пайпы, `try?` глотающие важные ошибки, ошибки в C-помощнике
   (незакрытые handles, не проверенные возвраты, переполнения буферов). Ничего в этих
   файлах не менять без падающего теста — только записать.
7. Ещё раз полный прогон — всё зелёное. Убедиться, что приложение собирается:
   `xcodebuild -project AKB.xcodeproj -scheme AKB -configuration Debug -derivedDataPath build build`.
8. Написать отчёт `TESTS-REPORT.md` (по-русски, коротко):
   - итог: сколько тестов, сколько прошло/упало до и после;
   - таблица правок в исходниках (файл, строка, что и почему);
   - таблица правок в тестах;
   - список найденных ошибок/подозрений с оценкой серьёзности (высокая/средняя/низкая) и
     предложением, что делать;
   - что осталось нестабильным или зависит от окружения.
9. **Не коммитить.** Не собирать DMG. Не менять `project.yml` и версию.

## Кандидаты на баги, которые Fable заметил при чтении (проверить и подтвердить/опровергнуть)

1. `BatteryMonitor.rediscoverDevices()` при ошибке ставит `phase = .failed(error)` напрямую,
   минуя `nextPhase`. Кнопка «Обновить список» при спящем телефоне стирает свежие показания
   с экрана. Тест: `rediscoverFailureKeepsFreshReading`.
2. `BatteryMonitor.settingsChanged()` создаёт `AlertPolicy` заново → `lastFiredStep = nil`.
   Если телефон уже на 25% и уведомление было, то смена интервала опроса или повтора −10%
   шлёт уведомление ещё раз. Юнит-тестом не покрыть (UNUserNotificationCenter), проверить
   чтением: `SettingsView.onChange(of: pollInterval)` → `settingsChanged()` → `refresh` →
   `evaluateAlert`. Также `policy` пересоздаётся в `evaluateAlert` при расхождении с Prefs.
3. `DeviceAddressResolver.addressFromARP`: `Prefs.localNetworkBlocked = true` ставится и когда
   `arp` просто вернул ненулевой код и sysctl пуст. Возможно, ложная подсказка про «Локальную сеть».
4. `ProcessRunner.run`: после `process.terminate()` и `finished.wait(2)` процесс, игнорирующий
   SIGTERM, остаётся жить. Проверить, нужен ли `kill(pid, SIGKILL)`.
5. `DeviceEventWatcher.runOnce`: `readabilityHandler = nil` сразу после завершения процесса —
   данные, оставшиеся в пайпе, могут быть не прочитаны (события REMOVE перед смертью помощника).
6. `IMobileDeviceProvider.listDevices`: fallback `cachedDevice()` берёт `deviceNames.keys.sorted().first`,
   если `selectedUDID` пуст — при двух телефонах в памяти выбор случайный (по алфавиту UDID).
7. `AKBLog.enqueue`: цепочка `Task` — проверить, что старые задачи освобождаются (нет
   бесконечного роста памяти при долгой работе).
8. `BatteryMonitor.refresh`: `devices = found` перезаписывает список даже если `found` пуст,
   при этом `selectedDevice = nil` — а `fail(.noDevice)` может оставить `.ready`. В popover
   показания есть, а в настройках телефона нет. Оценить, баг ли это для UI.

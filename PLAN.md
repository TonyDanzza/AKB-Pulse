# PLAN — «АКБ»: заряд iPhone в строке меню macOS

Автор плана: Fable 5.1. Исполнитель: Opus. Проверка: Fable 5.1.
Дата: 2026-09-09. Папка проекта: `/Users/tonydanzza/Documents/AKB` (пустая, git ещё нет).

## 0. Цель (одним абзацем)

Утилита для macOS 27 без иконки в Dock. В строке меню показывает заряд iPhone
(иконка + «72%»). Клик — нативный popover в стиле macOS 27 (Liquid Glass) с
деталями. Когда заряд падает ниже порога (по умолчанию **30%**) — иконка
становится красной и приходит системное уведомление. Есть окно настроек.

## 1. Факты, проверенные Fable на этой машине

| Что | Результат |
|---|---|
| macOS | 27.0 (26A5425a), Darwin 27 |
| Xcode | 27.0 (27A5252f) — `xcodebuild` работает |
| Bluetooth | Mac видит «iPhone TonyDanzza» (BLE, подключён) и «iPhone (Тони)» (не подключён). **Заряд по Bluetooth macOS для iPhone НЕ отдаёт** ни в `system_profiler`, ни в `ioreg`, ни в `com.apple.Bluetooth.plist`. Этот путь закрыт. |
| libimobiledevice | Установлен через Homebrew: `/opt/homebrew/bin/idevice_id`, `/opt/homebrew/bin/ideviceinfo` (v1.4.0). Библиотека: `/opt/homebrew/lib/libimobiledevice-1.0.dylib`, заголовки в `/opt/homebrew/include/libimobiledevice`. |
| Телефон сейчас | `idevice_id -l` и `idevice_id -n` пусты: телефон не на кабеле и Wi‑Fi‑синхронизация в Finder ещё не включена. **Живого устройства для теста может не быть — код должен корректно работать в состоянии «телефон не найден».** |
| Язык системы | en-US, затем ru-US. |
| xcodegen | Не установлен. |

## 2. Решения (уже приняты пользователем, не пересматривать)

- Источник данных: **Wi‑Fi через Finder** (lockdownd через usbmuxd, инструменты libimobiledevice). Не Bluetooth, не Shortcuts.
- Строка меню: **иконка + число процентов**.
- Порог тревоги: **30%** (настраивается).
- Дизайн: **только нативные элементы macOS 27** (SwiftUI, MenuBarExtra, Form, Gauge, SF Symbols, glass). Никаких кастомных «рисованных» контролов, никаких сторонних UI‑библиотек.
- Какой iPhone: пользователь не знает, какое из двух имён — iPhone 17. Поэтому приложение **само показывает модель** (ProductType → человеческое имя) и даёт выбрать. По умолчанию выбирать iPhone семейства 17 (ProductType `iPhone18,*`), иначе первый найденный.

## 3. Архитектура

```
AKB/
  project.yml                 # XcodeGen spec (см. §4)
  AKB.xcodeproj/              # генерируется, в git не коммитить
  Sources/AKB/
    AKBApp.swift              # @main, MenuBarExtra + Settings сцены
    Model/
      BatteryStatus.swift     # struct: percent, isCharging, externalConnected, fullyCharged, updatedAt
      PhoneDevice.swift       # struct: udid, name, productType, modelName (computed), transport (.wifi/.usb)
      ProductTypeMap.swift    # "iPhone18,3" -> "iPhone 17" и т.д. (см. §6)
    Services/
      BatteryProvider.swift   # protocol BatteryProvider { func listDevices() async throws -> [PhoneDevice]; func battery(for:) async throws -> BatteryStatus }
      IMobileDeviceProvider.swift  # реализация через Process + ideviceinfo/idevice_id
      IMobileDeviceOutputParser.swift # чистый парсер текстового вывода (тестируемый)
      ToolLocator.swift       # ищет бинарники: настройка → /opt/homebrew/bin → /usr/local/bin
      BatteryMonitor.swift    # @Observable, таймер опроса, состояние, публикует status/error/device
      AlertPolicy.swift       # чистая логика «когда слать уведомление» (тестируемая)
      NotificationService.swift # UNUserNotificationCenter
      LaunchAtLogin.swift     # SMAppService.mainApp
    Views/
      MenuBarLabel.swift      # рендер иконки для строки меню (см. §5.1)
      StatusPopoverView.swift # содержимое MenuBarExtra (.window)
      SettingsView.swift      # Settings-сцена, Form grouped
      EmptyStateView.swift    # «телефон не найден» / «нет libimobiledevice» с инструкцией
    Resources/
      Localizable.xcstrings   # base en + ru
      Assets.xcassets         # AppIcon (простой, можно placeholder из SF Symbol)
      AKB.entitlements        # sandbox OFF (нужен Process к /opt/homebrew)
  Tests/AKBTests/
      IMobileDeviceOutputParserTests.swift
      AlertPolicyTests.swift
      ProductTypeMapTests.swift
  README.md                   # на русском: включить Wi‑Fi в Finder, собрать, запустить, автозапуск
  .gitignore
```

Ключевые правила:
- Swift 6, strict concurrency. `BatteryMonitor` — `@MainActor @Observable`.
- Провайдер за протоколом: потом можно добавить другой источник без переписывания UI.
- Все вызовы `Process` — в фоне (`Task.detached` или actor), с таймаутом 10 с, никогда не блокировать main thread.
- Ошибки — отдельные `enum ProviderError: toolNotFound, noDevice, deviceUnreachable(udid), parseFailure, timeout`. UI показывает понятный текст для каждого.

## 4. Проект и сборка

1. `brew install xcodegen` (если не поставится — запасной путь: Swift Package executable + скрипт `scripts/bundle.sh`, который собирает `.app` с Info.plist; но сначала пробовать xcodegen).
2. `project.yml`:
   - target `AKB`, type `application`, platform macOS, deploymentTarget **26.0** (macOS 27 SDK; минимум 26, чтобы были glass API).
   - `LSUIElement = YES`, `CFBundleDisplayName = АКБ`, bundle id `ru.tonydanzza.akb`.
   - `NSUserNotificationsUsageDescription` не нужен на macOS, но добавить `NSHumanReadableCopyright`.
   - Signing: `CODE_SIGN_IDENTITY = "-"` (Sign to Run Locally), `CODE_SIGN_STYLE = Manual`. Ad‑hoc подписи достаточно для UNUserNotificationCenter и SMAppService.
   - App Sandbox **выключен** (иначе `Process` не запустит `/opt/homebrew/bin/ideviceinfo`). Hardened Runtime можно оставить выключенным.
   - Test target `AKBTests` (Swift Testing, `import Testing`).
3. Сборка: `xcodegen generate && xcodebuild -project AKB.xcodeproj -scheme AKB -configuration Debug -derivedDataPath build build`. Готовое приложение: `build/Build/Products/Debug/AKB.app`.
4. Тесты: `xcodebuild ... -scheme AKB test`.
5. `git init`, коммит в конце (сообщение по формату из инструкций Claude Code).

## 5. UI — строго нативно, macOS 27

### 5.1 Строка меню (MenuBarExtra)
- `MenuBarExtra { StatusPopoverView() } label: { MenuBarLabel(...) }` с `.menuBarExtraStyle(.window)`.
- Label: SF Symbol `iphone.gen3` (проверить существование через `NSImage(systemSymbolName:accessibilityDescription:)`, если nil — `iphone`) + `Text("72%")` моноширинными цифрами (`.monospacedDigit()`).
- Состояния:
  - **Обычное**: template‑иконка + «NN%».
  - **Заряжается**: добавить `bolt.fill` маленьким рядом (или символ `iphone.gen3.badge.bolt`, если существует — проверить).
  - **Ниже порога**: иконка и текст **красные**. Известная проблема: SwiftUI MenuBarExtra рендерит label как template и может выкинуть цвет. Поэтому label собирать как `Image(nsImage:)`, полученный через `ImageRenderer` из SwiftUI‑вью; для обычного состояния `isTemplate = true`, для красного — `isTemplate = false` с явным `.red`. Проверить **визуально** скриншотом (`screencapture -R` области строки меню) — это обязательный пункт приёмки.
  - **Телефон не найден**: `iphone.gen3.slash` (или `iphone.slash`) + без числа, серый/secondary.
  - **Нет libimobiledevice**: `exclamationmark.triangle` без числа.
- Число процентов можно выключить в настройках (тогда только иконка).

### 5.2 Popover (StatusPopoverView), ширина ~300pt
Сверху вниз, всё стандартными SwiftUI‑компонентами:
1. Заголовок: имя телефона (`DeviceName`) крупно, под ним модель (`iPhone 17 Pro`) secondary. Справа — маленький индикатор «Wi‑Fi / USB».
2. Большая цифра «72%» (`.font(.system(size: 44, weight: .semibold, design: .rounded))`, `.contentTransition(.numericText())`).
3. `Gauge(value:in:)` с `.gaugeStyle(.accessoryLinearCapacity)`, `tint`: зелёный/жёлтый/красный по уровню (как в iOS).
4. Строка статуса: «Заряжается» / «Не заряжается» / «Заряжен полностью» + «Обновлено 12:41» (`Text(date, style: .relative)` или `.time`).
5. `Divider()`.
6. Кнопки в один ряд: «Обновить» (`arrow.clockwise`), «Настройки…» (`SettingsLink`), «Выход» (`NSApplication.shared.terminate`). Использовать `.buttonStyle(.glass)`/`.glassEffect()` там, где это доступно и уместно (macOS 26+); если компилятор ругается — обычный `.bordered`. Никаких самодельных стеклянных фонов.
7. Состояние ошибки — вместо пунктов 1–4 показывается `EmptyStateView` (см. 5.4).

### 5.3 Настройки (Settings-сцена)
`Form { … }.formStyle(.grouped)`, окно ~420×360, без табов (одна секция‑группа достаточно; если получается длинно — `TabView` с двумя вкладками «Основные» / «Уведомления»).
- Секция «Телефон»: `Picker` со списком найденных устройств: «Имя — Модель (Wi‑Fi)». Кнопка «Обновить список». Если пусто — текст‑подсказка.
- Секция «Опрос»: интервал `Picker` 30 с / 1 мин / 2 мин / 5 мин (default 1 мин). Toggle «Показывать проценты в строке меню» (default on).
- Секция «Уведомления»: Toggle «Уведомлять о низком заряде» (default on). `Slider` порога 10…50, шаг 5, default 30, с подписью «30%». Toggle «Повторять каждые −10%» (default on; см. §7).
- Секция «Система»: Toggle «Запускать при входе» (SMAppService). Строка «libimobiledevice: найден в /opt/homebrew/bin» / «не найден» + кнопка «Указать путь…» (`NSOpenPanel`).
- Хранение: `@AppStorage` / `UserDefaults` с ключами через enum.

### 5.4 Пустые состояния (EmptyStateView)
Нативный `ContentUnavailableView(label:description:actions:)`:
- `noDevice`: заголовок «iPhone не найден», описание по шагам: «1. Подключи iPhone кабелем. 2. Finder → iPhone → Основные → включи «Показывать этот iPhone, если он подключён к Wi‑Fi». 3. Нажми «Доверять» на телефоне. 4. Отключи кабель — Mac и iPhone должны быть в одной сети Wi‑Fi.» Кнопка «Проверить снова».
- `toolNotFound`: «Нужен libimobiledevice», команда `brew install libimobiledevice` в моноширинном тексте с кнопкой «Скопировать».
- `deviceUnreachable`: «iPhone вне сети» + «Последний известный заряд: 72% (12:41)».

## 6. Данные: libimobiledevice через Process

- Найти устройства: `idevice_id -n` (Wi‑Fi) и `idevice_id -l` (USB). Объединить, пометить transport. Для каждого UDID: `ideviceinfo -n -u <udid> -k DeviceName` и `-k ProductType` (для USB без `-n`).
- Заряд: `ideviceinfo [-n] -u <udid> -q com.apple.mobile.battery`. Парсить строки `BatteryCurrentCapacity: 72`, `BatteryIsCharging: false`, `ExternalConnected: false`, `FullyCharged: false`.
- Парсер — чистая функция `parse(_ text: String) -> BatteryStatus?`, покрыть тестами (нормальный вывод, пустой, мусор, отсутствие ключа).
- Таймаут 10 с на каждый Process; при таймауте — `terminate()` и ошибка `.timeout`.
- Список устройств кешировать; заряд опрашивать только выбранного.
- `ProductTypeMap`: минимум семейства iPhone 15/16/17 + Air; неизвестный тип показывать как есть. Ориентир: `iPhone18,1` 17 Pro, `iPhone18,2` 17 Pro Max, `iPhone18,3` 17, `iPhone18,4` Air, `iPhone17,1` 16 Pro, `iPhone17,2` 16 Pro Max, `iPhone17,3` 16, `iPhone17,4` 16 Plus, `iPhone17,5` 16e, `iPhone16,1` 15 Pro, `iPhone16,2` 15 Pro Max, `iPhone15,4` 15, `iPhone15,5` 15 Plus. Если Opus не уверен в каком‑то ID — оставить с комментарием `// unverified`, не выдумывать.
- Дополнительно (не обязательно): вместо Process можно линковать `libimobiledevice-1.0.dylib` напрямую. **В этой версии не делать** — сначала рабочий Process‑вариант.

## 7. Логика уведомлений (AlertPolicy, чистая и тестируемая)

Вход: предыдущий и новый `BatteryStatus`, порог `T`, флаг `repeatEvery10`.
- Уведомить, когда percent впервые стал `< T` (пересечение сверху вниз) и не заряжается.
- Если `repeatEvery10`: повторно уведомлять при пересечении `T−10`, `T−20`, … (т.е. 30 → 20 → 10).
- Сброс «уже уведомляли», когда `isCharging == true` или percent `>= T`.
- Не уведомлять при первом же опросе после запуска, если телефон уже ниже порога? **Уведомлять** (пользователь именно этого хочет: узнать, что телефон сел). Но один раз.
- Текст: заголовок «iPhone почти разряжен», тело «iPhone TonyDanzza: 28%. Поставь на зарядку.» Звук по умолчанию. `interruptionLevel = .timeSensitive`.
- Тесты: 5–6 кейсов (пересечение, повтор, сброс при зарядке, стабильно низкий без повторов, шум ±1%).

## 8. Прочее

- `BatteryMonitor`: опрос по таймеру, плюс немедленный опрос при открытии popover и по кнопке «Обновить». После сна Mac (`NSWorkspace.didWakeNotification`) — немедленный опрос.
- Локализация: `Localizable.xcstrings`, base English + ru. Все строки через `String(localized:)`/`LocalizedStringKey`. Система у пользователя en‑US/ru — проверить, что при `-AppleLanguages "(ru)"` UI русский.
- Иконка приложения: сгенерировать простую (SF Symbol `iphone.gen3` на скруглённом квадрате) скриптом в `Assets.xcassets/AppIcon` — не тратить время, placeholder приемлем.
- README.md на русском, коротко: что это, как включить Wi‑Fi‑синхронизацию в Finder (шаги из §5.4), как собрать (`xcodegen generate` + `xcodebuild`), как запустить, как включить автозапуск, как проверить руками `ideviceinfo -n -q com.apple.mobile.battery`.
- `.gitignore`: `build/`, `*.xcodeproj/`, `xcuserdata/`, `.DS_Store`.

## 9. Порядок работы Opus

1. `brew install xcodegen`. Написать `project.yml`, сгенерировать, убедиться, что пустое приложение с `MenuBarExtra` собирается и запускается (`open build/.../AKB.app`, иконка появилась).
2. Модели + парсер + тесты парсера. Прогнать тесты.
3. `IMobileDeviceProvider` + `ToolLocator` + `BatteryMonitor`. Проверить руками состояние «нет устройства» (оно сейчас реальное).
4. `AlertPolicy` + тесты. `NotificationService`.
5. UI: label, popover, empty states, settings. Скриншоты: строка меню (обычное и красное состояние — для красного временно подставить фейковый статус через env‑переменную `AKB_FAKE_PERCENT=25`, оставить этот дебаг‑хук в коде, он полезен), popover, settings. Сохранять в `/Users/tonydanzza/Documents/AKB/screenshots/`.
6. Локализация, LaunchAtLogin, README, .gitignore, `git init` + commit.
7. Финальный отчёт (см. §10).

Фейковый режим (`AKB_FAKE_PERCENT`, опционально `AKB_FAKE_CHARGING=1`) обязателен: без живого телефона это единственный способ проверить UI и уведомления.

## 10. Критерии приёмки (Fable проверит именно это)

- [ ] `xcodegen generate && xcodebuild … build` проходит без ошибок и без warnings уровня «Swift 6 concurrency».
- [ ] `xcodebuild … test` — все тесты зелёные (парсер, AlertPolicy, ProductTypeMap).
- [ ] Приложение запускается, в Dock не появляется, в строке меню есть иконка.
- [ ] С `AKB_FAKE_PERCENT=72`: в строке меню «iPhone‑иконка 72%», popover показывает имя/модель/цифру/gauge/статус/кнопки.
- [ ] С `AKB_FAKE_PERCENT=25`: иконка и текст в строке меню **красные** (скриншот), приходит уведомление macOS (один раз).
- [ ] Без фейка (реальное состояние сейчас): popover показывает `ContentUnavailableView` с инструкцией про Finder, ничего не падает, лог без ошибок в цикле.
- [ ] Settings открывается через `SettingsLink`, все контролы — стандартные, `Form.grouped`.
- [ ] Нет сторонних зависимостей (SPM‑пакетов) кроме системных фреймворков.
- [ ] README на русском, скриншоты в `screenshots/`, git‑коммит есть.
- [ ] Отчёт Opus: что сделано, что не удалось, какие символы SF/API пришлось заменить и почему, точные команды сборки/запуска.

## 11. Обновления (Fable, после старта)

- **Живой телефон есть.** Пользователь включил Wi‑Fi‑синхронизацию в Finder. iPhone 17 = **«iPhone (Тони)»**, UDID `00008150-000A1B2C3D4E5F60`, ProductType `iPhone18,3` (подтверждено: 18,3 = iPhone 17). `idevice_id -n` его видит, `ideviceinfo -n -u <udid> -q com.apple.mobile.battery` отдаёт `BatteryCurrentCapacity`, `BatteryIsCharging`, `ExternalConnected`, `FullyCharged`. Приёмка теперь включает проверку на реальном телефоне (без фейка): в строке меню реальный процент.
- **Установка и передача.** Добавить `scripts/package.sh`: Release‑сборка → `AKB.app` → zip `dist/AKB-<version>.zip` (`ditto -c -k --keepParent`). В README раздел «Установка»: перетащить `AKB.app` в `/Applications`, при первом запуске macOS может заблокировать (ad‑hoc подпись) — правый клик → «Открыть», либо Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть». Раздел «Передать другому»: получателю нужны `brew install libimobiledevice` и галочка Wi‑Fi в Finder для его телефона. Пометить: для раздачи без предупреждений нужна подпись Developer ID + нотаризация (не в этой версии).
- Первая сессия Opus оборвалась. Уже написаны: `project.yml`, `Sources/AKB/Model/*`, `Services/{AlertPolicy,IMobileDeviceOutputParser,ProcessRunner,ProviderError,ToolLocator}.swift`. Тестов, UI, README, git ещё нет. Продолжать с проверки того, что есть, не переписывать с нуля без причины.

## 12. Фаза 2 — установка «без бубна» (запрос пользователя)

Цель: пользователь (или тот, кому передали) скачивает DMG, перетаскивает `AKB.app` в Программы, запускает — и всё работает. Homebrew не нужен. Единственный обязательный ручной шаг — один раз подключить iPhone кабелем и включить Wi‑Fi в Finder; его объясняет окно первого запуска.

### 12.1 Встроить libimobiledevice в приложение
- Скрипт `scripts/bundle-libimobiledevice.sh` (запускается как Run Script build phase в `project.yml` **до** подписи, а также вызывается из `package.sh`):
  1. Копирует `/opt/homebrew/bin/idevice_id` и `ideviceinfo` в `AKB.app/Contents/Helpers/`.
  2. Через `otool -L` рекурсивно собирает все не‑системные dylib (`libimobiledevice-1.0`, `libusbmuxd-2.0`, `libplist-2.0`, `libimobiledevice-glue-1.0`, `libtatsu`, `libssl`, `libcrypto` — точный список брать из otool, не с потолка) в `AKB.app/Contents/Frameworks/`.
  3. `install_name_tool -change` для каждой зависимости на `@executable_path/../Frameworks/<name>` (в helper‑бинарях) и `@loader_path/<name>` (внутри dylib), `-id` тоже переписать. Снять/переписать существующие подписи Homebrew: после правок `codesign --force -s - ` на каждом dylib и helper.
  4. Проверка в самом скрипте: `otool -L` не должен содержать `/opt/homebrew`; запустить `Contents/Helpers/idevice_id -n` с `DYLD_PRINT_LIBRARIES`‑нет, просто убедиться, что exit code 0 и нет «Library not loaded».
- `ToolLocator`: порядок поиска теперь **1) встроенные в бандл (`Bundle.main.bundleURL/Contents/Helpers`) → 2) путь из настроек → 3) /opt/homebrew/bin → 4) /usr/local/bin**. Настройка «Указать путь…» остаётся как аварийный вариант, в UI показывать «встроенный» статус.
- Лицензия: libimobiledevice/libplist/libusbmuxd — LGPL‑2.1. Положить `Contents/Resources/Licenses/` с текстами лицензий и упомянуть в README и в окне «О программе». Динамическая линковка LGPL‑совместима.
- Hardened Runtime оставить выключенным (ad‑hoc), иначе dylib без той же подписи не загрузятся.

### 12.2 DMG
- `scripts/make-dmg.sh`: Release‑сборка → `dist/AKB.app` → временная папка с `AKB.app` и симлинком `Applications` → `hdiutil create -volname "АКБ" -srcfolder … -ov -format UDZO dist/AKB-<version>.dmg`. Без сторонних инструментов (`create-dmg` не ставить). Фоновая картинка не нужна; достаточно двух иконок.
- Версия берётся из `project.yml` (`MARKETING_VERSION`), начинаем с 1.0.
- Проверка: смонтировать DMG (`hdiutil attach`), скопировать `AKB.app` в `/tmp/akb-test/`, запустить оттуда, убедиться, что телефон находится **без** `/opt/homebrew` (для чистоты теста временно запустить с `PATH=/usr/bin:/bin` и переименованным `/opt/homebrew/bin/ideviceinfo` нельзя — вместо этого скрипт проверки использует `otool -L` + запуск helper напрямую). Размонтировать.

### 12.3 Окно первого запуска (онбординг)
- `@AppStorage("hasCompletedOnboarding")`. При первом запуске (и через пункт «Показать инструкцию…» в настройках) открывается отдельное окно `Window("Добро пожаловать", id: "onboarding")`, ~460×420, обычное, не popover.
- Полностью нативно: `VStack` с заголовком, списком шагов (SF Symbol в кружке + текст), внизу живой индикатор статуса и кнопки. Никаких картинок‑скриншотов.
- Шаги (текст на русском, локализовано):
  1. `cable.connector` — «Подключи iPhone к Mac кабелем».
  2. `macwindow` — «В Finder выбери iPhone → вкладка «Основные» → включи «Показывать этот iPhone, если он подключён к Wi‑Fi»». Кнопка «Открыть Finder» (`NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))`).
  3. `hand.tap` — «На iPhone нажми «Доверять»».
  4. `wifi` — «Отключи кабель. Mac и iPhone должны быть в одной сети Wi‑Fi».
- Внизу живой статус, обновляется каждые 3 с, пока окно открыто: «Ищу iPhone…» (ProgressView) → «Найден: iPhone (Тони) · iPhone 17 · Wi‑Fi ✓» (зелёная галочка `checkmark.circle.fill`). Как только найден по Wi‑Fi (не только USB), кнопка «Готово» становится основной (`.keyboardShortcut(.defaultAction)`). Кнопка «Пропустить» есть всегда.
- Если приложение запущено не из `/Applications` (проверить `Bundle.main.bundleURL`), в том же окне сверху мягкая подсказка: «Лучше перенести АКБ в папку «Программы»» — без принуждения.
- Про Gatekeeper: без Developer ID при первом запуске на **чужом** Mac система покажет «не удаётся проверить разработчика». Это не решается кодом. В README — два предложения, как открыть (Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть»). В онбординг не выносить.

### 12.4 Приёмка фазы 2
- [ ] `scripts/make-dmg.sh` собирает `dist/AKB-1.0.dmg` без ошибок.
- [ ] `otool -L` по всем helper/dylib в бандле — ни одной ссылки на `/opt/homebrew`.
- [ ] Приложение, скопированное из DMG в `/tmp/akb-test/`, при запуске находит iPhone и показывает реальный процент (лог/скриншот).
- [ ] Первый запуск (сбросить ключ `hasCompletedOnboarding` через `defaults delete ru.tonydanzza.akb hasCompletedOnboarding`) показывает окно с 4 шагами и живым статусом, который зеленеет, когда телефон найден (скриншот `screenshots/onboarding.png`).
- [ ] Повторный запуск окно не показывает; из настроек его можно открыть снова.
- [ ] README: «Установка» = скачать DMG, перетащить, открыть; «Первый запуск» = 4 шага; «Если Mac не даёт открыть» = 2 предложения.
- [ ] Лицензии в бандле, отдельный git‑коммит фазы 2.

## 13. Статус на 2026-09-09 14:40 (Fable, перед третьим запуском Opus)

Вторая сессия Opus тоже оборвалась. Сейчас есть (не переписывать, только проверить и починить при необходимости):
`project.yml`, `Sources/AKB/Model/{BatteryStatus,PhoneDevice,ProductTypeMap}.swift`,
`Sources/AKB/Services/{AlertPolicy,BatteryMonitor,BatteryProvider,IMobileDeviceOutputParser,IMobileDeviceProvider,LaunchAtLogin,NotificationService,Prefs,ProcessRunner,ProviderError,ToolLocator}.swift`,
`Sources/AKB/Views/{EmptyStateView,Localization,MenuBarLabel,SymbolName}.swift`.
Пустые папки `Tests/AKBTests`, `scripts`, `screenshots`. `xcodegen` установлен. `.xcodeproj` ещё не генерировался, сборка ни разу не запускалась.

Ещё нет: `AKBApp.swift`, `StatusPopoverView.swift`, `SettingsView.swift`, `Resources/*` (xcstrings, Assets, entitlements), тесты, README, .gitignore, git.

Телефон в момент старта по Wi‑Fi **не виден** (`idevice_id -n` пуст) — возможно, спит или не в сети. Не ждать его: проверять через `AKB_FAKE_PERCENT`, а реальный телефон проверить в конце один раз (если появится — хорошо, если нет — записать в отчёт).

Порядок для этой сессии: сначала довести фазу 1 до сборки и зелёных тестов (§9 п.1–6), коммит. Фазу 2 (§12) — только после коммита фазы 1, отдельным коммитом. Коммитить часто, чтобы обрыв сессии не терял работу.

## 14. Фаза 3 — дизайн по Apple HIG (запрос пользователя, 2026-09-09 14:50)

Гайд: `/Users/tonydanzza/Documents/Похудение/ref/apple-hig.md` (конспект HIG; разделы «Типографика», «Компоновка», «Цвет», «Материалы», «SF Symbols», «Кнопки», «Gauges»). Прочитать эти разделы перед работой.
Жалобы пользователя на текущий popover: цифра слишком крупная (44 pt), полоса заряда слишком толстая, кнопки с подписями не нужны (их всего три). Цель: моментальная считываемость, спокойная композиция, «как системный popover Apple, только лучше». Только нативные элементы — правило §2 остаётся.

Ориентир — панели Control Center и меню Bluetooth в macOS 26/27: текст 13 pt, secondary 11 pt, тонкие индикаторы, много воздуха, один цвет = один смысл.

### 14.1 Popover (StatusPopoverView) — новая раскладка, ширина 280 pt, паддинг 14 по бокам, 12 сверху/снизу

Сетка 4 pt. Блоки сверху вниз (значения — отступы ПОСЛЕ блока):

1. **Идентичность** (VStack spacing 2, выравнивание leading):
   - Имя телефона: `.headline` (13 semibold), `lineLimit(1)`, `.primary`.
   - Вторая строка одним текстом-строкой: модель + тонкая вертикальная черта + транспорт: `iPhone 17 ▏Wi‑Fi` — `.subheadline` (11) `.secondary`. Разделитель — **не** «·» и не «|»-символ, а `Rectangle().frame(width: 1, height: 10).opacity(0.4)` (как уже сделано в `OnboardingView`, вынести в общий `HairlineSeparator` view). Иконку Wi‑Fi справа убрать — транспорт словом достаточно, лишний символ шумит.
   → 14 pt

2. **Герой** — одна строка `HStack(alignment: .firstTextBaseline, spacing: 8)`:
   - Процент: `.font(.system(size: 28, weight: .semibold, design: .rounded))` `.monospacedDigit()` `.contentTransition(.numericText())` — это ступень Title 1 / macOS Large Title, а не 44.
   - Рядом на той же базовой линии — состояние: `Label`/HStack из символа и текста `.body` (13) `.secondary`: «Заряжается» с `bolt.fill` зелёным, «Заряжен полностью» с `checkmark.circle.fill` зелёным, «Не заряжается» без символа, «Подключён к питанию» с `powerplug.fill` secondary. Пока заряжается — `symbolEffect(.breathe)` на молнии (HIG: breathe = текущая активность; если API нет на macOS 26 — `.pulse`, если и его нет — без эффекта, записать в отчёт).
   - Ничего справа. Spacer не нужен.
   → 8 pt

3. **Полоса заряда** — `Gauge(value:in:) { EmptyView() }` со стилем `.linearCapacity` (тонкая, системная, ~4 pt). Если на macOS 26 `.linearCapacity` рендерится толще 6 pt — заменить на `ProgressView(value:)` `.progressViewStyle(.linear)` с `.tint` (тоже нативный). Измерить по скриншоту, написать в отчёт, что выбрано и какая толщина.
   - **Цвет = смысл, три состояния, без жёлтого**: ниже порога и не заряжается — `.red`; заряжается или заряжен полностью — `.green`; иначе — `.primary` (монохром, как батарея в строке меню iOS/macOS). HIG «Цвет»: красить скупо, только настоящий акцент. Убрать `.yellow` для medium.
   - Анимировать изменение value `.animation(.smooth, value:)`.
   → 6 pt

4. **Время обновления** — `.caption` (10) `.tertiary`, leading: «Обновлено 14:44». Попробовать относительное время `Text(updatedAt, style: .relative)` с префиксом; если по-русски выглядит криво («14 сек.») — оставить абсолютное `.time`. Показать оба варианта на скриншоте не нужно, просто решить и записать.
   → 12 pt

5. `Divider()` → 10 pt

6. **Действия** — три кнопки **только иконки**, все одинакового размера (HIG: равные варианты различать стилем, не размером): `arrow.clockwise` (Обновить), `gearshape` (Настройки…), `power` (Выход). Стиль `.glass` как сейчас (если выглядит тяжело в ряду из трёх — `.bordered`; выбрать по скриншоту, объяснить). `.controlSize(.regular)`, `.labelStyle(.iconOnly)`, каждой — `.help("…")` и `.accessibilityLabel`. Раскладка: `[Обновить] [Настройки]  ……  [Выход]` — Spacer между настройками и выходом. Пока идёт опрос — кнопка «Обновить» показывает `ProgressView().controlSize(.small)` вместо иконки (HIG: активность внутри кнопки), не disabled-серую.

Общее: никаких кастомных фонов, теней, градиентов — окно `MenuBarExtra(.window)` даёт стекло само. Единственная «вау»-механика — тихие системные анимации: перекат цифр, плавное движение полосы, breathe на молнии.

### 14.2 Пустое состояние
- Ширина popover **одинаковая** (280) во всех состояниях — окно не должно прыгать между 300 и 360. Подобрать `minHeight`, чтобы `ContentUnavailableView` был виден целиком; описание — `.callout`/`.subheadline` secondary, шаги — списком с цифрами.
- В описание `noDevice` добавить пятый пункт одной строкой: «Если на Mac или iPhone включён VPN — разреши в нём доступ к локальной сети или выключи его на время поиска» (обнаружение по Wi‑Fi идёт через Bonjour/mDNS в локальной сети, VPN часто его режет). Локализовать (en + ru). Тот же абзац — в README, раздел «Если iPhone не находится».

### 14.3 Строка меню
Оставить как есть (иконка + молния + проценты уже хорошо читаются). Проверить только, что расстояние между молнией и числом ≥ 2 pt и молния не «прилипает» к иконке.

### 14.4 Настройки и онбординг — лёгкая сверка
- Настройки: окно не выше **560 pt**; всё стандартное `Form.grouped` без кастомных паддингов; подписи к секциям — системные (`Section("…")`), пояснения — `.footnote`/`.caption` `.secondary`. Кнопки в строках формы («Обновить список», «Показать инструкцию…») сделать `.controlSize(.small)` либо перенести вправо в строку с лейблом (`LabeledContent`), чтобы форма выглядела как системные Настройки.
- Онбординг: заголовок `.title2.weight(.semibold)` — ок; шаги `.body`, пояснения `.subheadline` `.secondary`; цифры шагов в кружках `.fill(.quaternary)` 28 pt; отступ между шагами 12. Ничего не изобретать.

### 14.5 Проверка (скриншоты в `screenshots/v2/`)
- `popover-72-light.png`, `popover-72-dark.png` (переключить внешний вид: `osascript -e 'tell app "System Events" to tell appearance preferences to set dark mode to true'` и обратно), `popover-25-red.png`, `popover-charging.png` (`AKB_FAKE_CHARGING=1`), `popover-nodevice.png`, `settings.png`, `onboarding.png`, реальный телефон если виден.
- В отчёте — таблица «элемент → шрифт/кегль/цвет/отступ» для popover, чтобы Fable сверил с §14.1.
- Тесты зелёные, сборка без warnings, отдельный коммит «Фаза 3: дизайн по HIG». Пересобрать DMG (`scripts/make-dmg.sh`).

## 15. Фаза 3.1 — правки пользователя после скриншотов v2 (2026-09-09 15:30)

1. **Пустое состояние «iPhone не найден» — текст мешанина.** Пять шагов сейчас одним абзацем. Сделать списком: `VStack(alignment: .leading, spacing: 6)`, каждый шаг — `HStack(alignment: .firstTextBaseline, spacing: 6)` из номера («1.» `.secondary`, `.monospacedDigit()`, фиксированная ширина ~16 pt, выравнивание trailing) и текста шага (`.callout`/`.subheadline`, `.secondary`, `multilineTextAlignment(.leading)`). Между шагами 6 pt, перед списком после заголовка — 8. Пункт 5 (VPN) — визуально такой же шаг, но можно отделить `Hairline`-нет, просто тем же списком. Убрать лишний воздух сверху над иконкой (сейчас пустого места больше, чем текста): подобрать `minHeight` так, чтобы контент был виден целиком без огромных полей, либо вместо `ContentUnavailableView` собрать то же нативно вручную (`Image` 40 pt hierarchical secondary → `Text(title).font(.headline)` → список → кнопка), если `ContentUnavailableView` не даёт управлять отступами. Кнопка «Проверить снова» — `.borderedProminent` оставить; но кнопка «Обновить» внизу в ряду действий делает то же — оставить обе (одна главная, вторая привычная), это ок.
2. **Настройки: убрать строку «libimobiledevice / встроен в приложение / Указать путь…».** Инструменты встроены в бандл, ручной путь никому не нужен. Удалить из `SettingsView`, удалить связанный код (`Prefs`-ключ пути, `NSOpenPanel`, строки локализации) — но **порядок поиска в `ToolLocator` оставить** (бандл → /opt/homebrew/bin → /usr/local/bin) как тихий запасной вариант; убрать только ветку «путь из настроек». Тесты должны остаться зелёными.
3. После удаления строки окно настроек, скорее всего, влезет в 560 pt целиком без скролла — проверить и подогнать высоту так, чтобы всё видно и снизу был стандартный отступ формы. Дополнительно, чтобы форма выглядела как системные Настройки: кнопки «Обновить список» и «Показать инструкцию…» перевести в `LabeledContent`-строки («Список устройств» → кнопка `.controlSize(.small)` справа; «Инструкция по подключению» → кнопка справа).
4. Скриншоты в `screenshots/v3/`: `popover-nodevice.png`, `settings.png`. Коммит «Фаза 3.1: список шагов и настройки без лишней строки». Пересобрать DMG.

## 16. Фаза 4 — заряд спящего iPhone: прямое подключение по IP (2026-09-09 16:20)

Пользователь отверг вариант «показывать старое число»: он хочет знать заряд телефона, который лежит и не трогается. Fable провёл эксперимент — способ есть.

### 16.1 Факты, проверенные Fable на живом телефоне (не перепроверять, использовать)
- Спящий iPhone на батарее **не** публикует Bonjour-запись `_apple-mobdev2._tcp`, поэтому `idevice_id -n` пуст. Но Wi‑Fi он не отключает: порт lockdownd **62078** на его IP (`192.168.1.11`, hostname `iPhone-Toni.local`) открыт **волнами** — 5–15 с доступен, 10–30 с нет (телефон просыпается для push). За 2 минуты наблюдений usbmuxd не увидел телефон ни разу, прямой TCP-запрос успешно снял заряд 5 раз из 14.
- Запись сопряжения читается без root через Apple usbmuxd: `usbmuxd_read_pair_record(udid, …)` (libusbmuxd, публичный API). В ней есть `WiFiMACAddress` = `34:10:be:d8:21:09`, и он **совпадает** с MAC телефона в `arp -an` (Private Wi‑Fi Address фиксирован для этой сети). Значит IP можно находить по MAC, даже если DHCP его сменит. VPN на LAN-адрес не влияет: VPN добавляет туннельный адрес, домашний остаётся.
- Прототип помощника на C **работает**: `/private/tmp/claude-501/-Users-tonydanzza-Documents-AKB/ade2693a-4ec1-4adc-8ea5-0d2d2fe9efd8/scratchpad/akb-direct.c` (скопировать в репозиторий как есть, затем дорабатывать). Он создаёт `idevice_private` вручную с `CONNECTION_NETWORK` и `sockaddr_in` телефона (структура из `src/idevice.h` libimobiledevice 1.4.0 — приватная, поэтому версия библиотеки **пиннится**: bundle-скрипт должен падать, если `brew list --versions libimobiledevice` ≠ 1.4.0), затем `lockdownd_client_new_with_handshake` (сам берёт pair record из usbmuxd, делает TLS) и `lockdownd_get_value(client, "com.apple.mobile.battery", NULL, …)`. Вывод в формате `ideviceinfo -q` («Key: value» построчно) — существующий `IMobileDeviceOutputParser` парсит его без изменений. Сборка: `clang -I/opt/homebrew/include -L/opt/homebrew/lib -limobiledevice-1.0 -lplist-2.0`. Коды: 0 ок, 3 рукопожатие не удалось (телефон в этот момент спит/недоступен), 4 GetValue не удался.

### 16.2 Помощник `akb-direct` в бандле
- Исходник `Helpers/akb-direct/akb-direct.c`. Цель в `project.yml`: target `akb-direct`, type `tool`, platform macOS, C; `HEADER_SEARCH_PATHS=/opt/homebrew/include`, `LIBRARY_SEARCH_PATHS=/opt/homebrew/lib`, `OTHER_LDFLAGS=-limobiledevice-1.0 -lplist-2.0 -lusbmuxd-2.0`. AKB зависит от него; bundle-скрипт копирует продукт в `AKB.app/Contents/Helpers/` и переписывает install names так же, как для `idevice_id`/`ideviceinfo` (dylib уже в `Frameworks/`), потом ad-hoc подпись. `otool -L` без `/opt/homebrew` — как раньше.
- Три режима CLI:
  1. `akb-direct battery <ip> <udid>` — как прототип (домен фиксирован).
  2. `akb-direct mac <udid>` — печатает `WiFiMACAddress` из pair record (`usbmuxd_read_pair_record` + libplist), нормализованный вид `aa:bb:cc:dd:ee:ff` в нижнем регистре с ведущими нулями.
  3. `akb-direct addr <udid>` — если usbmuxd сейчас видит устройство по сети (`usbmuxd_get_device_list`, `conn_type == CONNECTION_TYPE_NETWORK`), печатает его IPv4 из `conn_data` (`sockaddr_in`); IPv6 link-local пропускать (нужен IPv4). Код 5 — не найдено.
- Таймаут соединения: `socket_connect_addr` внутри библиотеки; в тесте неуспех возвращался быстро (ошибка -8). Дополнительно в Swift `ProcessRunner` с таймаутом 8 с.

### 16.3 Поиск IP (`DeviceAddressResolver`, Swift, actor)
Цепочка для выбранного UDID, каждый шаг проверяется реальным запросом батареи (рукопожатие с pair record пройдёт только у нужного телефона — чужой IP просто даст код 3):
1. Кэш `Prefs.lastKnownIP[udid]`.
2. Если usbmuxd видит устройство — `akb-direct addr` → обновить кэш.
3. MAC из `akb-direct mac` (кэшировать в Prefs) → `/usr/sbin/arp -an` → IP. **Внимание:** `arp` печатает MAC без ведущих нулей (`34:10:be:d8:21:9`) — нормализовать обе стороны перед сравнением. Чистая функция `ARPTable.parse(_:) -> [MAC: IP]` с тестами.
4. Ничего не нашли → `.deviceUnreachable`.
При успехе шага 3 обновить кэш IP.

### 16.4 Провайдер (`IMobileDeviceProvider.battery(for:)`)
- Сначала как сейчас — `ideviceinfo -n -u <udid> -q com.apple.mobile.battery` (быстро, когда телефон виден).
- Если не удалось — прямой путь: **окно повторов 40 с, попытка каждые 3 с** (`akb-direct battery <ip> <udid>`), потому что телефон отвечает волнами. Первый успех — возврат. Окно и шаг — параметры init (для тестов). Всё это внутри `battery(for:)`, `BatteryMonitor` не знает о деталях; `isRefreshing` остаётся true на время окна (кнопка «Обновить» крутит спиннер).
- Транспорт для отображения — `.wifi` в обоих случаях. В лог (`os.Logger`) писать, каким путём получен ответ и за сколько секунд — это нужно для приёмки.
- `listDevices()` — если usbmuxd пуст, но в Prefs есть сохранённый UDID с именем/моделью и кэшированным IP или MAC — вернуть это устройство из кэша (иначе `selectedDevice == nil` и до батареи дело не дойдёт). Сохранять имя/ProductType устройства в Prefs при каждом успешном `listDevices`.

### 16.5 Монитор и UI — «данные с возрастом» вместо «не найден»
- `.ready` сохраняется, пока есть данные. Если последний успешный ответ старше **15 мин** — строка состояния в popover: `moon.zzz.fill` `.secondary` + «Нет связи · данные 14:32» (разделитель — `Hairline`, не точка), полоса `.secondary`; строка меню — иконка+число с opacity 0.55. Старше **12 ч** — `.failed(.deviceUnreachable)` с текущим пустым состоянием. Уведомления о низком заряде — только по свежим данным.
- Тексты: `state.noLink` «Нет связи», `popover.dataAt` «данные %@» (en: "No link", "data %@").

### 16.6 Энергия
- Пауза опроса при `NSWorkspace.screensDidSleepNotification` и при блокировке сессии (`NSWorkspace.sessionDidResignActiveNotification`); возобновление + немедленный опрос на `screensDidWakeNotification` / `sessionDidBecomeActiveNotification`. Таймер — как сейчас.
- README, раздел «Расход батареи»: 3 предложения — один запрос это несколько пакетов и короткий TLS, телефон мы не будим, попытки к спящему телефону до него не доходят; при спящем экране Mac опрос стоит.

### 16.7 Тесты (Swift Testing)
- `ARPTableTests`: парсинг реального вывода `arp -an` (пример строки: `? (192.168.1.11) at 34:10:be:d8:21:9 on en0 ifscope [ethernet]`), нормализация MAC, несколько интерфейсов, `incomplete`.
- `DeviceAddressResolverTests` с фейковыми исполнителями: кэш → addr → arp → пусто.
- `RetryWindowTests`: окно 40/3 с инжектированными часами — прекращается по первому успеху, отдаёт последнюю ошибку по истечении.
- Старые 24 теста зелёные.

### 16.8 Приёмка
- Сборка без warnings; `otool -L` по `Helpers/akb-direct` без `/opt/homebrew`; DMG пересобран.
- **Главное:** приложение в реальном режиме, телефон лежит нетронутый ≥ 10 минут. В `log stream --predicate 'process == "AKB"'` видны успешные прямые чтения при пустом `idevice_id -n`. В строке меню — живой процент без приглушения. Скриншот `screenshots/v4/menubar-direct.png` + фрагмент лога в отчёт. Если телефон в этот момент на зарядке или разблокирован — это не считается, дождаться сна (обычно ≤ 5 мин после блокировки).
- Проверить деградацию: убрать кэш IP (`defaults delete ru.tonydanzza.akb lastKnownIP`) — цепочка должна найти IP через `mac`+`arp` без участия usbmuxd.
- Коммиты: (1) помощник + bundle-скрипт, (2) resolver + провайдер + тесты, (3) UI/энергия/README. Последняя строка коммита `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

## 17. Фаза 4.1 — быстрый повтор после неудачного опроса (2026-09-09)

Пользователь подтвердил: фаза 4 работает, процент живой при лежащем телефоне. Запрос: если опрос не попал в окно телефона (окно повторов 40 с исчерпано), не ждать полный интервал (до 5 мин), а повторить через **60 с**. После успеха — снова обычный интервал.

- `BatteryMonitor.scheduleTimer()`: следующий сон = `Prefs.pollInterval`, если последний опрос успешен; `min(60, Prefs.pollInterval)` — если последний опрос завершился ошибкой связи (`.deviceUnreachable`, `.noDevice`, `.timeout`). Ошибки `.toolNotFound`/`.parseFailure` — обычный интервал (повтор не поможет).
- Реализовать без пересоздания таймера: цикл `while` вычисляет задержку на каждой итерации по флагу `lastPollFailed`. Интервал из настроек по-прежнему подхватывается через `settingsChanged()`.
- Пауза при спящем экране (§16.6) сохраняется.
- Тест: вынести чистую функцию `nextPollDelay(interval:lastFailed:) -> Int` и покрыть 3 кейсами (успех → interval; неудача → 60; interval 30 и неудача → 30).
- Лог: строка «повтор через 60 с после неудачи».
- Проверка: `AKB_FAKE_PERCENT=72 AKB_FAKE_STALE_AFTER=5` с интервалом 5 мин — в логе повтор через минуту. Коммит «Фаза 4.1: повтор через минуту после неудачи», DMG пересобрать, приложение оставить в реальном режиме.

## 18. Фаза 4.2 — быстрая реакция на зарядку (2026-09-09)

Наблюдение пользователя: подключил зарядку — статус «Заряжается» появился через ~10 с (повезло с таймером); отключил — «Заряжается» висело ~2 минуты (минута до опроса + окно повторов 40 с, телефон задремал). Два исправления, оба обязательны:

### 18.1 События usbmuxd → немедленный опрос
- В помощник `akb-direct` добавить режим `watch`: подписка `usbmuxd_events_subscribe` (libusbmuxd 2.x API; если недоступен — `usbmuxd_subscribe`), на каждое событие печатать строку `ADD <udid> <network|usb>` / `REMOVE <udid>` и `fflush(stdout)`. Работает, пока не убьют (или до EOF на stdin — проверять stdin в отдельном потоке/`select`, чтобы процесс умирал вместе с приложением).
- Swift: `DeviceEventWatcher` (actor или @MainActor класс) держит `Process` с `akb-direct watch`, читает stdout построчно (`FileHandle.readabilityHandler` или `bytes.lines`), при `ADD` для выбранного UDID (или любого, если выбранного нет) вызывает `monitor.refresh(rediscover: true)` с дебаунсом 2 с. При `REMOVE` — тоже один опрос (телефон задремал или отключился; ответ пойдёт прямым путём и зафиксирует состояние). Перезапускать процесс при падении с backoff 5 с. Останавливать при паузе (спящий экран), запускать при пробуждении.
- Fake-режим: watcher не запускается.

### 18.2 На зарядке опрашивать каждые 15 с
- В `nextPollDelay` добавить параметр `isOnPower: Bool` (`status.externalConnected || status.isCharging` по последнему успешному статусу): если на питании — `min(interval, 15)`; неудача — как в §17; иначе interval. Тесты в `PollDelayTests` дополнить (на питании 300 → 15; на питании и неудача → 15; не на питании → interval).
- Уведомления, `AlertPolicy` — без изменений.
- README, «Расход батареи»: одно предложение — на зарядке опрос чаще, телефон тогда и так не спит.

### 18.3 Проверка
- Реальный телефон: подключить/отключить зарядку нельзя без пользователя, поэтому проверка косвенная: в логе при появлении телефона в usbmuxd (он появляется волнами сам) виден «событие ADD → опрос»; с `AKB_FAKE_CHARGING=1` — интервал 15 с в логе. `akb-direct watch` из терминала печатает ADD/REMOVE при волнах телефона (подождать до 2 мин).
- Тесты зелёные, сборка без warnings, `otool -L` чистый, коммит «Фаза 4.2: события usbmuxd и частый опрос на зарядке», DMG пересобрать. **Приложение установлено пользователем в /Applications** — после сборки DMG **заменить** `/Applications/AKB.app` новой версией (`pkill -x AKB; ditto` из Release-сборки) и запустить `open /Applications/AKB.app`, чтобы пользователь сразу тестировал; настройки не трогать.

## 19. Фаза 5 — экспорт лога для поддержки (2026-09-09)

Запрос: пользователь раздаёт приложение друзьям; в настройках нужна кнопка, чтобы друг сохранил лог и прислал его. Сейчас лог только в unified log (`os.Logger`), другу его не достать.

### 19.1 Файловый лог
- `FileLog` (actor): пишет те же строки, что идут в `os.Logger`, в `~/Library/Logs/AKB/akb.log` (формат: `2026-09-09 18:03:38.785 [provider] заряд 67% путём direct …`). Ротация: при превышении 2 МБ → `akb.1.log`, хранить 3 файла. Ошибки записи глотать (лог не должен ронять приложение).
- Единая точка: `AKBLog.info(category, message)` → и `Logger`, и `FileLog`. Заменить прямые вызовы `Self.log.info(...)` в monitor/provider/resolver/events на неё (категории сохранить). Приватность: строки уже `.public`; в файл пишутся как есть (там имя телефона, UDID, LAN-IP — это ок для поддержки, отметить в README).
- При старте писать шапку: версия приложения (`CFBundleShortVersionString`+build), macOS (`ProcessInfo.operatingSystemVersionString`), модель Mac (`sysctl hw.model`), путь запуска (`Bundle.main.bundleURL`), статус помощников (`ToolLocator`: найдены/встроены), интервал опроса, порог.

### 19.2 Кнопка в настройках
- Секция «Система», строка `LabeledContent("Лог приложения")` с кнопкой «Сохранить лог…» (`.controlSize(.small)`, как остальные). Нажатие: собрать один текстовый файл `АКБ-лог-2026-09-09-1803.txt` = шапка (§19.1) + содержимое `akb.log` и ротированных файлов в хронологическом порядке (последние 7 дней достаточно — просто все 3 файла) + хвост `/usr/bin/log show --info --last 2h --predicate 'subsystem == "ru.tonydanzza.akb"'` (через `ProcessRunner`, таймаут 15 с; если не удалось — строка «unified log недоступен»). `NSSavePanel` с предложенным именем, каталог по умолчанию — Рабочий стол. После сохранения — `NSWorkspace.shared.activateFileViewerSelecting([url])`.
- Вторая кнопка рядом не нужна. Под строкой — `.caption .secondary`: «В файле есть имя iPhone, его адрес в домашней сети и события приложения. Отправь его тому, кто помогает с настройкой.»
- Локализация en + ru (`settings.log.title`, `settings.log.save`, `settings.log.hint`).

### 19.3 Проверка
- Тесты: `FileLog` ротация (инжектированный каталог во временной папке, лимит 1 КБ для теста) — 2 кейса; сборка файла отчёта — 1 кейс (шапка присутствует, порядок файлов).
- Вручную: нажать кнопку, сохранить на Рабочий стол, открыть файл, убедиться, что там шапка и строки provider/events. Скриншот `screenshots/v5/settings-log.png`.
- Коммит «Фаза 5: файловый лог и кнопка «Сохранить лог…»», DMG пересобрать, **заменить `/Applications/AKB.app`** Release-сборкой и запустить (как в §18.3), настройки не трогать. Файл отчёта после ручной проверки удалить с Рабочего стола.

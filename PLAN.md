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

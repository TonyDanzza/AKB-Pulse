# АКБ — заряд iPhone в строке меню macOS

Маленькая утилита для macOS 26+: показывает заряд iPhone в строке меню
(иконка и «72 %»), красит иконку красным и присылает уведомление, когда
телефон садится ниже порога. Иконки в Dock нет.

Данные берутся по Wi-Fi через `lockdownd` — теми же утилитами
libimobiledevice, что использует Finder. Bluetooth заряд iPhone для Mac
не отдаёт, поэтому этот путь не используется.

![Строка меню](screenshots/menubar-real.png)

## Что нужно один раз сделать на телефоне

1. Подключи iPhone к Mac кабелем.
2. Finder → выбери iPhone в боковом меню → вкладка «Основные» → включи
   «Показывать этот iPhone, если он подключён к Wi-Fi». Нажми «Применить».
3. На iPhone нажми «Доверять» и введи код-пароль.
4. Отключи кабель. Mac и iPhone должны быть в одной сети Wi-Fi.

Проверить руками, что всё готово:

```bash
idevice_id -n                                   # должен вывести UDID
ideviceinfo -n -u <UDID> -q com.apple.mobile.battery
```

Второй командой телефон отвечает строками `BatteryCurrentCapacity`,
`BatteryIsCharging`, `ExternalConnected`, `FullyCharged` — это и есть всё,
что читает приложение.

## Установка

1. Возьми `AKB.app` из архива `dist/AKB-1.0.zip` (собирается
   `./scripts/package.sh`) и перетащи в папку «Программы».
2. Первый запуск: подпись ad-hoc, поэтому macOS может сказать, что не
   может проверить разработчика. Правый клик по `AKB.app` → «Открыть» →
   «Открыть» ещё раз. Либо: Системные настройки → «Конфиденциальность и
   безопасность» → внизу «Всё равно открыть».
3. При первом запуске система спросит разрешение на уведомления —
   разреши, иначе не придёт предупреждение о низком заряде.
4. Автозапуск включается в настройках приложения: «Система» →
   «Запускать при входе».

## Сборка из исходников

Нужны Xcode 26+ и `xcodegen` (`brew install xcodegen`).

```bash
cd /Users/tonydanzza/Documents/AKB
xcodegen generate
xcodebuild -project AKB.xcodeproj -scheme AKB -configuration Debug \
    -derivedDataPath build build
open build/Build/Products/Debug/AKB.app
```

Тесты:

```bash
xcodebuild -project AKB.xcodeproj -scheme AKB -configuration Debug \
    -derivedDataPath build test -destination 'platform=macOS'
```

Release-архив для раздачи:

```bash
./scripts/package.sh        # → dist/AKB-1.0.zip
```

### Отладка без телефона

Приложение умеет притворяться. Переменные окружения:

| Переменная | Что делает |
|---|---|
| `AKB_FAKE_PERCENT=72` | показывает выдуманные 72 % вместо опроса телефона |
| `AKB_FAKE_CHARGING=1` | к фейковому заряду добавляет «заряжается» |
| `AKB_FAKE_NO_DEVICE=1` | «iPhone не найден» — проверить пустое состояние |
| `AKB_FAKE_NO_TOOL=1` | «нет libimobiledevice» — проверить второе пустое состояние |

```bash
AKB_FAKE_PERCENT=25 build/Build/Products/Debug/AKB.app/Contents/MacOS/AKB &
```

Логи приложения:

```bash
log stream --predicate 'subsystem == "ru.tonydanzza.akb"' --level info
```

## Настройки

- **Телефон** — какой iPhone опрашивать, если их несколько. По умолчанию
  выбирается устройство семейства iPhone 17, иначе первое найденное.
- **Опрос** — интервал 30 с / 1 мин / 2 мин / 5 мин и переключатель
  «показывать проценты в строке меню».
- **Уведомления** — порог 10…50 % (по умолчанию 30 %) и повтор на каждой
  ступени −10 % (30 → 20 → 10).
- **Система** — автозапуск и путь к утилитам libimobiledevice, если они
  лежат не в `/opt/homebrew/bin`.

Опрос выполняется также при пробуждении Mac и при открытии окна.

## Передать другому

Собери `./scripts/package.sh` и отдай `dist/AKB-1.0.zip`. Получателю
понадобится:

- поставить утилиты: `brew install libimobiledevice`
  (в этой версии они не встроены в приложение);
- включить для своего телефона галочку Wi-Fi в Finder — шаги выше;
- при первом запуске обойти Gatekeeper так, как описано в «Установке».

Чтобы приложение открывалось без предупреждений на чужом Mac, нужны
подпись Developer ID и нотаризация у Apple. В этой версии их нет.

## Как устроено

```
Sources/AKB/
  AKBApp.swift                    MenuBarExtra(.window) + сцена Settings
  Model/                          BatteryStatus, PhoneDevice, ProductTypeMap
  Services/
    BatteryProvider.swift         протокол источника данных
    IMobileDeviceProvider.swift   idevice_id / ideviceinfo через Process
    IMobileDeviceOutputParser.swift  чистый парсер (покрыт тестами)
    ProcessRunner.swift           Process вне главного потока, таймаут 10 с
    ToolLocator.swift             поиск бинарников
    BatteryMonitor.swift          @Observable состояние и таймер опроса
    AlertPolicy.swift             когда слать уведомление (покрыто тестами)
    NotificationService.swift     UNUserNotificationCenter
    LaunchAtLogin.swift           SMAppService
  Views/                          MenuBarLabel, StatusPopoverView,
                                  SettingsView, EmptyStateView
Tests/AKBTests/                   24 теста, Swift Testing
```

Сторонних зависимостей нет — только системные фреймворки.
Песочница выключена: без неё `Process` не сможет запустить
`/opt/homebrew/bin/ideviceinfo`.

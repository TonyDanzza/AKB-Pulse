# План: переименование в «AKB Pulse», версия 1.2, чистка личных данных перед GitHub

Исполнитель: Opus. Не коммитить. DMG не собирать. Bundle id `ru.tonydanzza.akb` и `PRODUCT_NAME: AKB` НЕ менять (иначе слетят настройки пользователя и пути в скриптах).

1. `project.yml`: `MARKETING_VERSION: "1.2"`, `CURRENT_PROJECT_VERSION: "3"`, `CFBundleName: "AKB Pulse"`, `CFBundleDisplayName: "AKB Pulse"`.
2. Имя в интерфейсе. `grep -rn "АКБ" Sources/` — везде, где это название приложения (заголовки онбординга/настроек/popover, шапка `SupportReport` «===== АКБ =====», имя файла отчёта `АКБ-лог-…`), заменить на «AKB Pulse» (файл отчёта — `AKB-Pulse-лог-yyyy-MM-dd-HHmm.txt`). Слова «АКБ» в смысле «аккумулятор» в подсказках/комментариях не трогать, если они не про название. Обновить тесты, которые проверяют эти строки (`FileLogTests`, `FileLogEdgeTests` → регулярка имени файла, `SupportReportTests`).
3. `scripts/make-dmg.sh`, `scripts/package.sh`: имя образа `AKB-Pulse-<версия>.dmg`, заголовок тома «AKB Pulse», если он есть. Пути к `AKB.app` не менять.
4. `README.md`: заголовок и первые строки — «AKB Pulse»; упоминания «АКБ» как названия → «AKB Pulse»; строку с DMG → `AKB-Pulse-1.2.dmg`. Добавить короткий раздел «Установка из GitHub»: скачать DMG из Releases, перетащить в Программы, при первом запуске правой кнопкой → Открыть (приложение подписано ad-hoc).
5. Чистка личных данных (репозиторий уйдёт на GitHub): настоящий UDID устройства заменить на выдуманный `00008150-000A1B2C3D4E5F60` во всех файлах кроме `build/` и `dist/` (Tests, README, PLAN.md, TESTS-*.md, FIX-*.md). Формат сохранить (8-16 hex). Проверить, что старого UDID нигде нет вне `build/` и `dist/`.
6. `.gitignore`: добавить `*.log` не нужно; убедиться, что `build/`, `dist/`, `*.xcodeproj/` там есть (уже есть).
7. `xcodegen generate`; полный `xcodebuild … test` зелёный (213 тестов); `xcodebuild … build` без предупреждений. Собранное приложение должно показывать в `Contents/Info.plist` `CFBundleDisplayName = AKB Pulse`, `CFBundleShortVersionString = 1.2` (`defaults read build/Build/Products/Debug/AKB.app/Contents/Info.plist CFBundleDisplayName`).
8. В ответе: список изменённых файлов, результат test/build, вывод `grep -rn "АКБ" Sources/ README.md` (что осталось и почему).

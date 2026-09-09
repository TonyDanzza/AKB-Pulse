#!/bin/bash
# Собирает Release и делает готовый к раздаче образ dist/AKB-<версия>.dmg.
#
#   ./scripts/make-dmg.sh
#
# Внутри образа: AKB.app и ярлык на «Программы». Сторонних инструментов не нужно —
# только hdiutil из macOS.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
DIST="$ROOT/dist"
BUILD="$ROOT/build"

VERSION="$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' project.yml)"
: "${VERSION:=1.0}"
DMG="$DIST/AKB-$VERSION.dmg"

echo "==> Генерирую проект"
xcodegen generate >/dev/null

echo "==> Собираю Release $VERSION"
xcodebuild -project AKB.xcodeproj -scheme AKB -configuration Release \
    -derivedDataPath "$BUILD" build | tail -2

APP="$BUILD/Build/Products/Release/AKB.app"
[ -d "$APP" ] || { echo "AKB.app не собрался"; exit 1; }

echo "==> Проверяю, что libimobiledevice встроен"
[ -x "$APP/Contents/Helpers/ideviceinfo" ] || {
    echo "В бандле нет Contents/Helpers/ideviceinfo"; exit 1; }
if otool -L "$APP"/Contents/Helpers/* "$APP"/Contents/Frameworks/*.dylib \
        | grep -q "/opt/homebrew"; then
    echo "В бандле остались ссылки на /opt/homebrew"; exit 1
fi

echo "==> Собираю образ"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/AKB.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create -volname "АКБ" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo
echo "Готово: $DMG ($(du -h "$DMG" | cut -f1))"

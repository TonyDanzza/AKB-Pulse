#!/bin/bash
# Собирает Release и кладёт готовый архив в dist/.
#
#   ./scripts/package.sh
#
# Результат: dist/AKB-<версия>.zip — распаковывается в AKB.app.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
DIST="$ROOT/dist"
BUILD="$ROOT/build"

VERSION="$(awk '/MARKETING_VERSION:/ {gsub(/"/, "", $2); print $2; exit}' project.yml)"
: "${VERSION:=1.0}"

echo "==> Генерирую проект"
xcodegen generate

echo "==> Собираю Release $VERSION"
xcodebuild -project AKB.xcodeproj -scheme AKB -configuration Release \
    -derivedDataPath "$BUILD" build | tail -3

APP="$BUILD/Build/Products/Release/AKB.app"
[ -d "$APP" ] || { echo "AKB.app не собрался"; exit 1; }

mkdir -p "$DIST"
rm -rf "$DIST/AKB.app" "$DIST/AKB-$VERSION.zip"
cp -R "$APP" "$DIST/AKB.app"

echo "==> Пакую в zip"
ditto -c -k --keepParent "$DIST/AKB.app" "$DIST/AKB-$VERSION.zip"

echo
echo "Готово: $DIST/AKB-$VERSION.zip"
echo "Проверка подписи:"
codesign -dv "$DIST/AKB.app" 2>&1 | sed 's/^/    /'

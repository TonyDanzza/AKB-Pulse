#!/bin/bash
# Кладёт idevice_id и ideviceinfo вместе со всеми не-системными dylib
# внутрь AKB.app, чтобы приложению не нужен был Homebrew.
#
#   ./scripts/bundle-libimobiledevice.sh <путь к AKB.app>
#
# Вызывается как Run Script build phase (до подписи) и из package.sh.
# Результат: Contents/Helpers/{idevice_id,ideviceinfo},
#            Contents/Frameworks/*.dylib,
#            Contents/Resources/Licenses/.
set -euo pipefail

APP="${1:-${BUILT_PRODUCTS_DIR:-}/${WRAPPER_NAME:-}}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "note: бандл '$APP' не найден — шаг пропущен"
    exit 0
fi

SRC_BIN="${LIBIMOBILEDEVICE_BIN:-/opt/homebrew/bin}"
if [ ! -x "$SRC_BIN/idevice_id" ]; then
    echo "warning: $SRC_BIN/idevice_id не найден, утилиты не встроены"
    exit 0
fi

HELPERS="$APP/Contents/Helpers"
FRAMEWORKS="$APP/Contents/Frameworks"
LICENSES="$APP/Contents/Resources/Licenses"
rm -rf "$HELPERS"
mkdir -p "$HELPERS" "$FRAMEWORKS" "$LICENSES"

# --- 1. Копируем сами утилиты -------------------------------------------------
for tool in idevice_id ideviceinfo; do
    cp -f "$SRC_BIN/$tool" "$HELPERS/$tool"
    chmod u+w "$HELPERS/$tool"
done

# --- 2. Рекурсивно собираем не-системные зависимости --------------------------
# Системными считаем /usr/lib и /System — их копировать нельзя и не нужно.
is_system() {
    case "$1" in
        /usr/lib/*|/System/*) return 0 ;;
        *) return 1 ;;
    esac
}

collect() {
    local binary="$1"
    local dep
    while read -r dep; do
        [ -z "$dep" ] && continue
        is_system "$dep" && continue
        local name
        name="$(basename "$dep")"
        if [ ! -f "$FRAMEWORKS/$name" ]; then
            local real
            real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dep")"
            cp -f "$real" "$FRAMEWORKS/$name"
            chmod u+w "$FRAMEWORKS/$name"
            collect "$FRAMEWORKS/$name"
        fi
    done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
}

for tool in idevice_id ideviceinfo; do
    collect "$HELPERS/$tool"
done

# --- 3. Переписываем пути -----------------------------------------------------
for tool in idevice_id ideviceinfo; do
    otool -L "$HELPERS/$tool" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        is_system "$dep" && continue
        install_name_tool -change "$dep" \
            "@executable_path/../Frameworks/$(basename "$dep")" "$HELPERS/$tool"
    done
done

for lib in "$FRAMEWORKS"/*.dylib; do
    [ -e "$lib" ] || continue
    install_name_tool -id "@loader_path/$(basename "$lib")" "$lib"
    otool -L "$lib" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        is_system "$dep" && continue
        install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$lib"
    done
done

# --- 4. Подпись (после правок старая подпись Homebrew недействительна) ---------
for lib in "$FRAMEWORKS"/*.dylib; do
    [ -e "$lib" ] || continue
    codesign --force --sign - --timestamp=none "$lib" 2>/dev/null
done
for tool in idevice_id ideviceinfo; do
    codesign --force --sign - --timestamp=none "$HELPERS/$tool" 2>/dev/null
done

# --- 5. Лицензии (LGPL-2.1: динамическая линковка, тексты кладём в бандл) ------
copy_license() {
    local formula="$1"
    local dir="/opt/homebrew/opt/$formula"
    for candidate in COPYING COPYING.LESSER LICENSE LICENSE.txt; do
        if [ -f "$dir/$candidate" ]; then
            cp -f "$dir/$candidate" "$LICENSES/$formula-$candidate"
        fi
    done
}
for formula in libimobiledevice libplist libusbmuxd libimobiledevice-glue openssl@3; do
    copy_license "$formula"
done
cat > "$LICENSES/README.txt" <<'TXT'
АКБ использует утилиты и библиотеки проекта libimobiledevice
(libimobiledevice, libplist, libusbmuxd, libimobiledevice-glue),
распространяемые под LGPL-2.1, и OpenSSL (Apache-2.0).
Библиотеки подключены динамически и лежат в Contents/Frameworks —
их можно заменить своей сборкой.
Исходники: https://github.com/libimobiledevice
TXT

# --- 6. Проверка --------------------------------------------------------------
FAIL=0
for binary in "$HELPERS"/* "$FRAMEWORKS"/*.dylib; do
    [ -e "$binary" ] || continue
    if otool -L "$binary" | grep -q "/opt/homebrew"; then
        echo "error: $(basename "$binary") всё ещё ссылается на /opt/homebrew"
        otool -L "$binary" | grep "/opt/homebrew"
        FAIL=1
    fi
done

if "$HELPERS/idevice_id" -l >/dev/null 2>&1 || [ $? -le 1 ]; then
    :
else
    echo "error: встроенный idevice_id не запускается"
    FAIL=1
fi

[ $FAIL -eq 0 ] || exit 1
echo "note: встроено $(ls "$FRAMEWORKS" | wc -l | tr -d ' ') библиотек и 2 утилиты"

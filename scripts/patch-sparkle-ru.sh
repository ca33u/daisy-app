#!/bin/bash
# Бэклог 16 Р-4: дополняет русскую локализацию Sparkle ключами, которых
# в ней нет.
#
# Почему скриптом сборки, а не руками: Sparkle приходит пакетом, и любое
# его обновление приносит свежие ресурсы поверх правки. Ручная правка
# исчезнет молча — кнопка снова станет английской, и никто не заметит,
# пока не посмотрит на русскую систему.
#
# Скрипт только ДОПОЛНЯЕТ: ключ, который в Sparkle уже есть, остаётся
# как есть. Когда апстрим примет перевод, этот шаг станет пустым сам по
# себе, без отдельного решения.
set -euo pipefail

ADDITIONS="${SRCROOT}/scripts/sparkle-ru-additions.strings"
TARGET_STRINGS="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/Sparkle.framework/Versions/B/Resources/ru.lproj/Sparkle.strings"

if [[ ! -f "${ADDITIONS}" ]]; then
    echo "note: no Sparkle ru additions at ${ADDITIONS}; nothing to merge"
    exit 0
fi
if [[ ! -f "${TARGET_STRINGS}" ]]; then
    # Не ошибка: сборки без встраивания фреймворка (индексация, превью)
    # сюда попадают штатно.
    echo "note: Sparkle ru.lproj not embedded in this build; skipping"
    exit 0
fi

ADDITIONS="${ADDITIONS}" TARGET_STRINGS="${TARGET_STRINGS}" /usr/bin/python3 <<'PY'
import os, plistlib, subprocess, sys

additions_path = os.environ["ADDITIONS"]
target_path = os.environ["TARGET_STRINGS"]

def read_strings(path):
    # .strings в собранном фреймворке — бинарный plist; в репозитории —
    # обычный текст. plutil читает оба.
    out = subprocess.run(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", path],
                         capture_output=True)
    if out.returncode != 0:
        print(f"error: could not read {path}: {out.stderr.decode().strip()}", file=sys.stderr)
        sys.exit(1)
    return plistlib.loads(out.stdout)

current = read_strings(target_path)
additions = read_strings(additions_path)

added = {k: v for k, v in additions.items() if k not in current}
if not added:
    print("note: Sparkle ru.lproj already has every key we add")
    sys.exit(0)

current.update(added)
with open(target_path, "wb") as handle:
    plistlib.dump(current, handle, fmt=plistlib.FMT_BINARY)
print(f"note: added {len(added)} Russian Sparkle string(s): {', '.join(sorted(added))}")
PY

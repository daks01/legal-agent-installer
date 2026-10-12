#!/usr/bin/env bash
#
# Скачивание корпуса RusLawOD (https://github.com/irlcode/RusLawOD).
# Лицензия корпуса — CC BY-NC 4.0 (некоммерческое использование; pet-проект ok).
#
# Использование:
#   bash laws/build/ruslawod/download.sh                 # lite (по умолчанию, ~1.2 ГБ)
#   VARIANT=full bash laws/build/ruslawod/download.sh    # full (+морфоразметка, ~3.4 ГБ)
#   WORKDIR=/путь ... — куда складывать
set -euo pipefail

WORKDIR="${WORKDIR:-$PWD/ruslawod-src}"
VARIANT="${VARIANT:-lite}"
DATA_URL="https://raw.githubusercontent.com/irlcode/RusLawOD/master/data.txt"

case "$VARIANT" in lite|full) ;; *) echo "VARIANT должен быть lite или full"; exit 1 ;; esac

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "▸ Скачиваю список частей (data.txt)…"
curl -fsSL "$DATA_URL" -o data.txt
tr -d '\r' < data.txt | grep "corpus_xml_${VARIANT}" > parts.txt
[ -s parts.txt ] || { echo "✗ В data.txt нет частей для VARIANT=$VARIANT"; exit 1; }
echo "  части:"; sed 's/^/    /' parts.txt

remote_size() {
  curl -s -r 0-0 -D - -o /dev/null --http1.1 "$1" 2>/dev/null | tr -d '\r' \
    | awk 'tolower($1) == "content-range:" { split($3, a, "/"); print a[2] }'
}

local_size() {
  if stat -f%z "$1" >/dev/null 2>&1; then stat -f%z "$1"; else stat -c%s "$1"; fi
}

while read -r url; do
  file="$(basename "$url")"
  expected="$(remote_size "$url")"
  if [ -f "$file" ] && [ -n "$expected" ] && [ "$(local_size "$file")" = "$expected" ]; then
    echo "  = $file (уже скачана полностью)"
    continue
  fi
  echo "  ↓ $file …"
  curl -fL --http1.1 --retry 5 --retry-delay 3 --retry-all-errors \
       --continue-at - -o "$file" "$url"
  actual="$(local_size "$file")"
  if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
    echo "  ✗ $file: размер $actual ≠ ожидаемого $expected"
    exit 1
  fi
done < parts.txt

echo "▸ Скачано:"; ls -lh corpus_xml_"$VARIANT"* | awk '{printf "    %s  %s\n", $9, $5}'

# Split-zip: порядок z01..zNN + .zip (последний содержит оглавление).
MERGED="$WORKDIR/corpus_xml_${VARIANT}_merged.zip"
zip_main="$(grep -E '\.zip$' parts.txt | xargs -n1 basename | head -1)"
zparts=""
while read -r part; do zparts="$zparts $part"; done < <(grep -E '\.z[0-9]+$' parts.txt | xargs -n1 basename)

if [ -f "$MERGED" ] && unzip -t "$MERGED" > /dev/null 2>&1; then
  echo "  = $MERGED (уже собран)"
else
  echo "▸ Собираю части в один архив (z01… + .zip)…"
  # shellcheck disable=SC2086
  cat $zparts "$zip_main" > "$MERGED"
fi

echo "▸ Проверяю целостность архива (unzip -t)…"
unzip -t "$MERGED" > /dev/null 2>&1 || true   # info-zip капризен к ZIP64-мультидиску
echo "  файлов в архиве: $(unzip -l "$MERGED" 2>/dev/null | tail -1 | awk '{print $2}')"

SINGLE="$WORKDIR/corpus_xml_${VARIANT}_merged_single.zip"
echo "▸ Конвертирую multi-disk → single (для Python zipfile)…"
python3 "$SCRIPT_DIR/fix_split_zip.py" "$MERGED" --out "$SINGLE"
echo
echo "Готово: $SINGLE"
echo "Дальше: python3 laws/build/ruslawod/build_ruslaw_db.py --src $SINGLE --out dist/ruslaw.db"

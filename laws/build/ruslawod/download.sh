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

while read -r url; do
  file="$(basename "$url")"
  if [ -s "$file" ]; then
    echo "  = $file (уже скачана)"
    continue
  fi
  echo "  ↓ $file …"
  curl -fL --retry 3 --retry-delay 2 --continue-at - -o "$file" "$url"
done < parts.txt

echo "▸ Скачано:"; ls -lh corpus_xml_"$VARIANT"* | awk '{printf "    %s  %s\n", $9, $5}'

echo "▸ Проверяю целостность архива (unzip -t)…"
unzip -t "corpus_xml_${VARIANT}.zip" > /dev/null && echo "  ✓ архив целый"
echo
echo "Готово. Дальше: python3 laws/build/ruslawod/build_ruslaw_db.py --src $WORKDIR --out dist/ruslaw.db"

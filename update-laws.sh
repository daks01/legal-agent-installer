#!/usr/bin/env bash
#
# Обновление локальной базы законов (laws) — без Docker и Postgres.
# Скачивает готовые laws.db(.gz) из GitHub Release (или берёт локальный файл)
# и заменяет базу в ~/.local/share/legal-agent/law7-lite/.
#
# Использование:
#   bash update-laws.sh                          # из релиза (RELEASE_BASE_URL)
#   bash update-laws.sh /path/laws.db.gz         # из локального файла
#   bash update-laws.sh --with-publications      # + база публикаций (~160 МБ)
set -euo pipefail

RELEASE_BASE_URL="${RELEASE_BASE_URL:-}"
DEST="$HOME/.local/share/legal-agent/law7-lite"
WITH_PUBLICATIONS=0
SRC=""

for arg in "$@"; do
  case "$arg" in
    --with-publications) WITH_PUBLICATIONS=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) SRC="$arg" ;;
  esac
done

mkdir -p "$DEST"

hash_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

install_db() {  # $1 = laws.db | laws-publications.db
  local name="$1"
  local tmp; tmp="$(mktemp -d)"
  if [ -f "$LAWS_DB_SRC_LOCAL" ] && [ "$name" = "laws.db" ]; then
    gunzip -c "$LAWS_DB_SRC_LOCAL" > "$tmp/$name"
  elif [ -n "$SRC" ] && [ "$name" = "laws.db" ]; then
    case "$SRC" in
      *.gz) gunzip -c "$SRC" > "$tmp/$name" ;;
      *) cp "$SRC" "$tmp/$name" ;;
    esac
  elif [ -n "$RELEASE_BASE_URL" ]; then
    echo "▸ Скачиваю $name.gz из релиза…"
    curl -fL --silent --show-error "$RELEASE_BASE_URL/$name.gz" | gunzip -c > "$tmp/$name"
    if curl -fsL "$RELEASE_BASE_URL/$name.sha256" -o "$tmp/$name.sha256" 2>/dev/null; then
      local expected actual
      expected="$(cat "$tmp/$name.sha256")"
      actual="$(hash_file "$tmp/$name")"
      [ "$expected" = "$actual" ] || { echo "✗ SHA256 не совпал для $name"; rm -rf "$tmp"; exit 1; }
      echo "  ✓ контрольная сумма совпала"
    fi
  else
    echo "✗ Нет источника: задай RELEASE_BASE_URL или укажи файл: bash update-laws.sh /path/laws.db.gz"
    rm -rf "$tmp"; exit 1
  fi
  mv "$tmp/$name" "$DEST/$name"
  rm -rf "$tmp"
  echo "  ✓ $name обновлён"
}

LAWS_DB_SRC_LOCAL="${LAWS_DB_SRC:-}"
install_db laws.db
[ "$WITH_PUBLICATIONS" = "1" ] && install_db laws-publications.db

if command -v python3 >/dev/null 2>&1; then
  python3 - "$DEST/laws.db" <<'PYEOF'
import sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
meta = dict(con.execute("SELECT key, value FROM meta").fetchall())
con.close()
print(f"\n✓ База законов обновлена. Снапшот: {meta.get('snapshot_date')} "
      f"(собран {meta.get('built_at')}): {meta.get('articles')} статей, "
      f"{meta.get('interpretations')} писем, {meta.get('decisions')} документов ВС.")
print("  Напомни юристу: данные снапшотные — для актуальности проверять первоисточник.")
PYEOF
fi

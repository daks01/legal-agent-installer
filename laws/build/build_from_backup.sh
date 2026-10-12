#!/usr/bin/env bash
#
# Пересборка laws.db и laws-publications.db из публичного бэкапа law7.
# Для РАЗРАБОТЧИКА (пользователю не нужно: он скачивает готовые *.db.gz из релиза).
#
# Требования: curl, tar, python3, PostgreSQL 15+ (brew install postgresql@15 или Docker).
# Использование:
#   bash laws/build/build_from_backup.sh                 # всё, в ./law7-build и ./dist
#   SKIP_PUBLICATIONS=1 bash laws/build/build_from_backup.sh   # без базы публикаций
#   KEEP_PG=1 ... — не останавливать локальный Postgres после сборки
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
WORKDIR="${WORKDIR:-$PWD/law7-build}"
OUTDIR="${OUTDIR:-$PWD/dist}"
PGPORT="${PGPORT:-5433}"
PGBIN="${PGBIN:-}"
SKIP_PUBLICATIONS="${SKIP_PUBLICATIONS:-0}"
KEEP_PG="${KEEP_PG:-0}"

say() { printf '▸ %s\n' "$*"; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

hash_file() {  # $1 — файл; печатает sha256
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

# --- зависимости ---
for tool in curl tar python3 gzip; do command -v "$tool" >/dev/null 2>&1 || die "Не найден $tool"; done
if [ -z "$PGBIN" ]; then
  if command -v pg_restore >/dev/null 2>&1; then PGBIN="$(dirname "$(command -v pg_restore)")"
  elif [ -x /opt/homebrew/opt/postgresql@15/bin/pg_restore ]; then PGBIN=/opt/homebrew/opt/postgresql@15/bin
  else die "Нет PostgreSQL 15+. Установи: brew install postgresql@15 (или используй Docker-вариант law7)"; fi
fi

mkdir -p "$WORKDIR" "$OUTDIR"
cd "$WORKDIR"

# --- 1. найти последний бэкап law7 ---
say "Ищу последний бэкап law7…"
curl -fsSL "https://raw.githubusercontent.com/mikhashev/law7/main/docs/BACKUP_RESTORE.md" -o BACKUP_RESTORE.md
DRIVE_URL="$(grep -oE 'https://drive\.google\.com/file/d/[A-Za-z0-9_-]+' BACKUP_RESTORE.md | head -1)"
FILE="$(grep -oE 'law7_backup_[0-9]+_[0-9]+\.tar\.gz' BACKUP_RESTORE.md | head -1)"
SHA="$(grep -oE '[0-9a-f]{64}' BACKUP_RESTORE.md | head -1)"
[ -n "$DRIVE_URL" ] && [ -n "$FILE" ] || die "Не удалось распарсить BACKUP_RESTORE.md"
DRIVE_ID="$(printf '%s' "$DRIVE_URL" | sed -E 's|.*/d/([^/]+).*|\1|')"
say "Бэкап: $FILE (sha256 ${SHA:0:12}…)"

# --- 2. скачать и проверить ---
if [ ! -f "$FILE" ]; then
  say "Скачиваю ($(basename "$FILE"))…"
  curl -L --fail -o "$FILE" "https://drive.usercontent.google.com/download?id=$DRIVE_ID&export=download&confirm=t"
fi
ACTUAL="$(hash_file "$FILE")"
[ "$ACTUAL" = "$SHA" ] || die "SHA256 не совпал: $ACTUAL ≠ $SHA (файл повреждён?)"
say "Контрольная сумма совпала"

# --- 3. распаковка ---
say "Распаковываю…"
rm -rf "$WORKDIR"/law7_backup_*
tar xzf "$FILE"
DUMP="$(find "$WORKDIR" -name 'law7.dump' | head -1)"
[ -n "$DUMP" ] || die "В архиве нет law7.dump"

# --- 4. локальный PostgreSQL ---
PGDATA="$WORKDIR/pgdata"
if [ ! -d "$PGDATA" ]; then
  say "Инициализирую локальный PostgreSQL ($PGBIN)…"
  "$PGBIN/initdb" -D "$PGDATA" -U law7 --auth=trust -E UTF8 >/dev/null
fi
if ! "$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1; then
  "$PGBIN/pg_ctl" -D "$PGDATA" -o "-p $PGPORT -k $WORKDIR" -l "$WORKDIR/pg.log" start >/dev/null
  sleep 2
fi
PSQL() { "$PGBIN/psql" -h 127.0.0.1 -p "$PGPORT" -U law7 "$@"; }
PSQL -d postgres -c "DROP DATABASE IF EXISTS law7;" >/dev/null
PSQL -d postgres -c "CREATE DATABASE law7;" >/dev/null
say "Восстанавливаю дамп…"
"$PGBIN/pg_restore" -h 127.0.0.1 -p "$PGPORT" -U law7 -d law7 --no-owner --no-privileges "$DUMP" 2>/dev/null

# --- 5. экспорт CSV ---
EXP="$WORKDIR/export"; rm -rf "$EXP"; mkdir -p "$EXP"
say "Экспортирую таблицы…"
PSQL -d law7 -c "\copy (SELECT code_id, article_number, article_number_consultant, article_title, article_text, version_date, is_current, is_repealed, source FROM code_article_versions) TO '$EXP/articles.csv' CSV HEADER" >/dev/null
PSQL -d law7 -c "\copy (SELECT oi.id, coalesce(ga.agency_name_short, ga.agency_name), oi.document_number, oi.document_date, oi.title, substr(oi.full_content, 1, 100000), oi.legal_topic, oi.validity_status, oi.source_url, (length(oi.full_content) > 100000) FROM official_interpretations oi LEFT JOIN government_agencies ga ON ga.id = oi.agency_id WHERE oi.full_content IS NOT NULL AND length(oi.full_content) > 100) TO '$EXP/interpretations.csv' CSV HEADER" >/dev/null
PSQL -d law7 -c "\copy (SELECT id, court_type, court_level, decision_type, case_number, decision_date, title, summary, legal_issues::text, binding_nature, source_url FROM court_decisions) TO '$EXP/decisions.csv' CSV HEADER" >/dev/null

# --- 6. сборка SQLite ---
SNAPSHOT="$(PSQL -d law7 -t -A -c 'SELECT max(publish_date) FROM documents;')"
say "Собираю laws.db (снапшот публикаций: $SNAPSHOT)…"
python3 "$SCRIPT_DIR/build_laws_db.py" "$EXP" "$OUTDIR/laws.db" \
  "source_file=$FILE" "source_sha256=$SHA" "snapshot_date=$SNAPSHOT"

if [ "$SKIP_PUBLICATIONS" != "1" ]; then
  say "Экспортирую публикации (1,1 млн строк, ~1-2 минуты)…"
  PSQL -d law7 -c "\copy (SELECT d.eo_number, substr(d.eo_number,1,4), left(regexp_replace(coalesce(d.name,''), '\s+', ' ', 'g'), 300), left(regexp_replace(regexp_replace(coalesce(d.complex_name,''), '<[^>]*>', ' ', 'g'), '\s+', ' ', 'g'), 300), d.document_number, d.document_date, d.publish_date, dc.pdf_url, dc.html_url, left(dc.full_text, 2000) FROM documents d LEFT JOIN document_content dc ON dc.document_id = d.id) TO '$EXP/publications.csv' CSV HEADER" >/dev/null
  say "Собираю laws-publications.db…"
  python3 "$SCRIPT_DIR/build_publications_db.py" "$EXP" "$OUTDIR/laws-publications.db"
fi

# --- 7. gzip + sha256 ---
say "Упаковываю артефакты…"
( cd "$OUTDIR"
  gzip -kf laws.db; hash_file laws.db > laws.db.sha256
  if [ -f laws-publications.db ]; then gzip -kf laws-publications.db; hash_file laws-publications.db > laws-publications.db.sha256; fi )
say "Готово: $OUTDIR/laws.db.gz, laws.db.sha256"$([ -f "$OUTDIR/laws-publications.db.gz" ] && echo ", laws-publications.db.gz" || true)

# --- 8. остановить Postgres ---
if [ "$KEEP_PG" != "1" ]; then
  "$PGBIN/pg_ctl" -D "$PGDATA" stop >/dev/null 2>&1 || true
  say "Postgres остановлен (KEEP_PG=1 — оставить запущенным)"
fi

cat <<EOF

Дальше (для релиза):
  1. Приложите dist/laws.db.gz (+ laws.db.sha256, при необходимости laws-publications.db.gz)
     к GitHub Release.
  2. Пользователи обновляются: bash update-laws.sh (или повторный install.sh).
EOF

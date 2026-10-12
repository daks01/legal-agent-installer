# laws/build — пересборка базы законов (для разработчика)

Пользователю это **не нужно**: `install.sh` скачивает готовые `laws.db.gz`
из GitHub Release. Здесь — путь пересборки, когда law7 публикует новый бэкап.

## Что делает `build_from_backup.sh`

1. Находит последний публичный бэкап law7 (парсит `BACKUP_RESTORE.md`) и скачивает его;
2. Проверяет SHA256;
3. Поднимает **локальный** PostgreSQL (brew-пакет, Docker не обязателен) и
   восстанавливает дамп;
4. Экспортирует таблицы в CSV;
5. Собирает `laws.db` (ядро) и `laws-publications.db` (публикации, опционально);
6. Кладёт в `dist/`: `*.db.gz` + `*.sha256` для релиза.

## Запуск

```bash
brew install postgresql@15          # один раз (или используйте Docker-вариант law7)
bash laws/build/build_from_backup.sh
# → dist/laws.db.gz (≈60 МБ), dist/laws-publications.db.gz (≈160 МБ)

SKIP_PUBLICATIONS=1 bash laws/build/build_from_backup.sh   # только ядро
KEEP_PG=1 ...                                              # не останавливать Postgres
```

## Что откуда берётся

| Артефакт | Таблицы law7 | Наш отбор |
| --- | --- | --- |
| `laws.db` | `code_article_versions` | 6 232 статьи 22 кодексов (тексты действующих редакций) |
| `laws.db` | `official_interpretations` | 13 444 письма с текстом (Минфин/ФНС), текст ≤100 тыс. знаков |
| `laws.db` | `court_decisions` | 619 документов ВС (краткие описания) |
| `laws-publications.db` | `documents` + `document_content` | 1 136 605 публикаций: реквизиты, названия (≤150/170 зн.), аннотация (≤500) |

Не берём: метаданные документов без полезных полей, Qdrant-векторы (в law7
семантический поиск не реализован), аннотации низкого качества.

## Лицензии

- Тексты — официальные документы РФ (ГК РФ ст. 1259 — не объект авторских прав).
- Сбор данных — [mikhashev/law7](https://github.com/mikhashev/law7), AGPL-3.0.
- Наш код сервера — Apache-2.0; атрибуция law7 сохраняется в README/скилле.

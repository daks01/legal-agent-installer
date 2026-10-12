# laws-mcp (law7-lite)

MCP-сервер с **локальной базой российского права** — без Docker, без Postgres,
без интернета: один файл SQLite + Python.

## Что внутри

| Данные | Объём | Источник |
| --- | --- | --- |
| Тексты статей 22 кодексов РФ | 6 232 статьи | law7 (сборка из kremlin.ru / pravo.gov.ru) |
| Письма и разъяснения Минфина/ФНС | 13 444 с полным текстом | law7 |
| Документы Верховного Суда (краткие описания) | 619 | law7 |
| Официальные публикации pravo.gov.ru (2019–2026) | 1 136 605 | law7 — **опционально** (`laws-publications.db`) |

Тексты законов — официальные документы (ГК РФ ст. 1259, не объект авторских прав).
Сборка данных — проект [mikhashev/law7](https://github.com/mikhashev/law7) (AGPL-3.0).

**Важно**: база — снапшот на дату сборки (см. `laws_status`), а не «живые» данные.
Агент обязан указывать дату снапшота и советовать сверку с первоисточником.

## Инструменты

| Инструмент | Назначение |
| --- | --- |
| `laws_status` | Снапшот, состав, проверка обновлений у law7 |
| `list_codes` | Список кодексов |
| `search_code_articles` / `get_code_article` | Поиск и точный текст статьи |
| `search_interpretations` / `get_interpretation` | Письма Минфина/ФНС по дате/органу |
| `search_court_decisions` / `get_court_decision` | Документы ВС |
| `search_publications` / `get_publication` | Официальные публикации (опциональная база) |

## Запуск

```bash
uvx --from . laws-mcp
```

Переменные: `LAWS_DB` (по умолчанию `~/.local/share/legal-agent/law7-lite/laws.db`),
`LAWS_PUBLICATIONS_DB` (опциональная база публикаций).

## Пересборка данных (для разработчика)

Не нужна для обычной установки — пользователь скачивает готовые `*.db.gz`
из релиза. Полный путь пересборки (скачать бэкап law7 → Postgres → SQLite):

```bash
bash laws/build/build_from_backup.sh          # нужен postgresql@15 (brew) + python3
```

Подробности — `laws/build/README.md`.

# NOTES.md — проблемы и решения в ходе разработки

## Этап 0 (подготовка репозитория)

### 1. `ru-legal-mcp` отсутствует на PyPI → ставим `AlsKozlov/ru-legal` с GitHub

Проверка: `https://pypi.org/pypi/ru-legal-mcp/json` → **404**.
Пакет лежит внутри GitHub-репо `AlsKozlov/ru-legal` (Apache 2.0) по пути
`mcps/ru-legal-aggregator/`. По решению заказчика берём его.

**Установка (проверено вручную на macOS)**:

```bash
git clone --depth 1 https://github.com/AlsKozlov/ru-legal.git ~/.local/share/legal-agent/ru-legal
uvx --from ~/.local/share/legal-agent/ru-legal/mcps/ru-legal-aggregator ru-legal-mcp
```

**Важно**: `packs/` (145 скиллов) лежат в корне репо и **не попадают в wheel**.
Автопоиск `packs/` из установленного пакета не работает (проверено: падает с
`FileNotFoundError`). Поэтому MCP обязана получать переменную окружения
`RU_LEGAL_PACKS_ROOT=~/.local/share/legal-agent/ru-legal/packs` — она прописана
в `templates/opencode.jsonc.template` через плейсхолдер `{{LEGAL_AGENT_HOME}}`.

**Smoke-тест (stdio, JSON-RPC)**: initialize OK (сервер `ru-legal` 3.4.8),
tools: `list_skills`, `find_skill`, `get_skill`, `get_skill_index`;
`list_skills` вернул **143 скилла** (в README заявлено 145 — расхождение
некритично, часть файлов без валидного frontmatter отбрасывается при загрузке).

Статус: **решено**. Установщик (Этап 3) должен: клонировать репо, подставлять
`{{LEGAL_AGENT_HOME}}` = абсолютный путь `$HOME/.local/share/legal-agent`
(два плейсхолдера в шаблоне: `{{DEEPSEEK_KEY}}` и `{{LEGAL_AGENT_HOME}}`).

### 2. Формат `opencode.jsonc`: `apiKey` лежит в `options`

В шаблоне из `plan.md` ключ указан как `provider.deepseek.apiKey`.
По официальной схеме `https://opencode.ai/config.json` правильный путь:
`provider.deepseek.options.apiKey`. Исправлено в `templates/opencode.jsonc.template`.

Также в шаблон добавлен `"model": "deepseek/DeepSeek-V4-Flash"` — чтобы агент
запускался «из коробки» без ручного выбора модели. К проверке на Этапе 2:
корректен ли API-id `deepseek-chat` и нужно ли вообще переопределять `models`.

Статус: **исправлено в шаблоне**, требует проверки на Этапе 2.

---

## Этап 1 (MCP-сервер `sudrf-scraper-mcp`)

### 1. sudrfscraper — не CLI/JAR, а Spring Boot с локальным веб-интерфейсом

План предполагал «запуск `sudrfscraper.jar` через `subprocess.run` с таймаутом
600 сек и возвратом результата». Реальность (releases `tochno-st/sudrfscraper`,
v0.3.0.3):

- релиз — zip (~190 МБ, x64) с `run.sh`/`run.bat`, **встроенной JRE** и
  Spring Boot приложением; системная Java не нужна;
- управление — через HTTP API на `localhost:8080`:
  `POST /check_request` → `GET /init` → результаты; `POST /submit_captcha`;
  `GET /finish`; живой прогресс — только по WebSocket;
- сбор **асинхронный** (часы), капчу на сайтах судов вводит **человек**
  в браузере (`/scraping`).

**Решение (реализовано)**: MCP поднимает `run.sh` фоновым процессом (лог
`app.log`) и работает через HTTP API. Вместо таймаута 600 сек — ожидание
старта приложения (≤ 90 сек). Синхронно «дождаться всего сбора» нельзя из-за
капчи. Инструментов семь: `run_sudrf_scrape`, `get_sudrf_status`,
`get_sudrf_results`, `submit_sudrf_captcha`, `stop_sudrf_scraper`,
`check_sudrf_environment`, `list_sudrf_regions`.

### 2. Параметра `limit` в sudrfscraper нет

Из плана убран: приложение не умеет ограничивать число дел. Ограничивать
выборку нужно регионами / периодом / статьёй. Зафиксировано в README и в
описании инструмента.

### 3. Проверки окружения

- **Java**: релиз везёт встроенную JRE (`*/jre/bin/java`) — системная не нужна;
- **Firefox**: обязателен (Firefox WebDriver), проверяется в preflight;
- релизы только **x64**: на Apple Silicon нужна Rosetta (на этой машине нет
  Firefox/Rosetta — полный E2E на ней невозможен).

### 4. Smoke-тест (MCP stdio, 2026-10-11)

Сервер стартует; 7 инструментов; `list_sudrf_regions` — 86 регионов;
`check_sudrf_environment` и `run_sudrf_scrape` без установленного приложения
дают понятные инструкции, а не падают. Ruff: чисто.

**Осталось для полного E2E** (чистая машина, Этап 3/5): скачать релиз,
запустить приложение, реальный сбор (например, ст. 20.3 КоАП по одному региону).

Статус: **MCP готов**, E2E — на чистой машине после install.sh.

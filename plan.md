# plan.md — План разработки установщика

## Общая стратегия

Разработка идёт **итерациями**. После каждой итерации — рабочий артефакт,
который можно протестировать. Не пытаться сделать всё сразу.

Приоритет: **сначала MVP (этапы 0–3), потом обвес (этапы 4–6)**.

---

## Этап 0. Подготовка репозитория (30 минут)

**Задачи**:
1. Создать структуру папок (см. `AGENTS.md` → «Файлы проекта»)
2. Создать `README.md` с описанием проекта (что это, для кого, как запустить)
3. Создать `templates/opencode.jsonc.template` — шаблон конфига
4. Инициализировать git-репозиторий

**Артефакт**: пустой скелет репо.

---

## Этап 1. MCP-сервер `sudrf-scraper-mcp` (2-3 часа)

**Уточнение после изучения sudrfscraper**: это не CLI/JAR, а Spring Boot
приложение с локальным веб-интерфейсом (localhost:8080); сбор асинхронный,
капча вводится вручную. MCP общается с приложением по HTTP API.
Подробности — `NOTES.md` (Этап 1).

**Задачи**:
1. Создать `pyproject.toml` с зависимостями (`fastmcp`, `httpx`)
2. Написать `server.py`:
   - Инструменты: `run_sudrf_scrape`, `get_sudrf_status`, `get_sudrf_results`,
     `submit_sudrf_captcha`, `stop_sudrf_scraper`, `check_sudrf_environment`,
     `list_sudrf_regions`
   - Подъём приложения: фоновый `run.sh` из `SUDRF_HOME`, ожидание старта ≤ 90 сек
   - Проверки Firefox и встроенной JRE — с понятными ошибками
   - `limit` не поддерживается sudrfscraper (см. `NOTES.md`)
3. Написать `README.md` для MCP-сервера (как установить, как тестировать)
4. Протестировать локально (MCP stdio smoke-тест): сервер стартует, инструменты
   отвечают, ошибки окружения — понятные

**Артефакт**: работающий MCP-сервер.

**Риски**:
- Полный E2E требует Firefox и x64-сборку (на Apple Silicon — Rosetta);
  проверка — на чистой машине (Этап 3/5)
- Капча вручную — авторешение в backlog

---

## Этап 2. Шаблон конфига OpenCode (1 час)

**Задачи**:
1. Написать `templates/opencode.jsonc.template` с плейсхолдером `{{DEEPSEEK_KEY}}`
2. Проверить, что конфиг валиден (JSONC)
3. Проверить, что OpenCode подхватывает MCP из этого формата
4. Написать функцию `write_config()` в будущем `install.sh`

**Содержимое шаблона** (`ru-legal-mcp` нет на PyPI — ставим `AlsKozlov/ru-legal`
с GitHub, см. `NOTES.md`; плейсхолдеры `{{DEEPSEEK_KEY}}` и `{{LEGAL_AGENT_HOME}}`):
```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "deepseek": {
      "options": { "apiKey": "{{DEEPSEEK_KEY}}" },
      "models": { "DeepSeek-V4-Flash": { "id": "deepseek-chat" } }
    }
  },
  "mcp": {
    "ru-legal": {
      "type": "local",
      "command": ["uvx", "--from", "{{LEGAL_AGENT_HOME}}/ru-legal/mcps/ru-legal-aggregator", "ru-legal-mcp"],
      "environment": { "RU_LEGAL_PACKS_ROOT": "{{LEGAL_AGENT_HOME}}/ru-legal/packs" }
    },
    "office-docs":   { "type": "local", "command": ["uvx", "office-docs-mcp", "serve"] },
    "sudrf-scraper": { "type": "local", "command": ["uvx", "sudrf-scraper-mcp"] }
  }
}
```

**Артефакт**: валидный шаблон, проверенный на реальном OpenCode.

---

## Этап 3. Главный установщик `install.sh` — MVP (4-5 часов)

**Задачи**:
1. Шапка скрипта: `set -euo pipefail`, цветной вывод, функции `log_info/log_error`
2. **Шаг 1**: Определение ОС (`uname -s`)
3. **Шаг 2**: Проверка зависимостей:
   - `command -v curl`, `command -v git`
   - Node.js (>= 20): если нет — установить через `nvm` или `brew`
   - Python 3.11+: если нет — установить через `brew`/`apt`
   - `uv`: если нет — `curl -LsSf https://astral.sh/uv/install.sh | sh`
4. **Шаг 3**: Запрос DeepSeek API Key:
   ```bash
   read -s -p "Вставьте DeepSeek API Key: " DEEPSEEK_KEY
   ```
5. **Шаг 4**: Установка OpenCode:
   ```bash
   curl -fsSL https://opencode.ai/install | bash
   ```
6. **Шаг 5**: Запись `opencode.jsonc`:
   - Скопировать `templates/opencode.jsonc.template` в `~/.config/opencode/`
   - Заменить `{{DEEPSEEK_KEY}}` на `$DEEPSEEK_KEY`
   - Если файл уже есть — сделать `.bak`
7. **Шаг 6**: Установка скилла `source-locked-ru`:
   - Скопировать `skills/source-locked-ru/` в `~/.config/opencode/skills/`
8. **Шаг 7**: Установка MCP-серверов:
   - `git clone --depth 1 https://github.com/AlsKozlov/ru-legal.git ~/.local/share/legal-agent/ru-legal` (обновление — `git -C ... pull`)
   - `uvx --from ~/.local/share/legal-agent/ru-legal/mcps/ru-legal-aggregator ru-legal-mcp` (проверка, с `RU_LEGAL_PACKS_ROOT`)
   - `uvx office-docs-mcp --help` (проверка)
   - `uv tool install sudrf-scraper-mcp` (наш кастомный)
9. **Шаг 8**: Установка `sudrfscraper`:
   - Проверить Java (`command -v java`)
   - Проверить Firefox (`command -v firefox` на Linux, `/Applications/Firefox.app` на macOS)
   - Скачать JAR в `~/.local/share/legal-agent/sudrfscraper/`
10. **Шаг 9**: Создать `~/knowledge_base/` с подпапками:
    - `court_practice/` (для JSON от скрапера)
    - `consultant/` (для экспорта из КонсультантПлюс)
    - `templates/` (для шаблонов договоров)
11. **Шаг 10**: Финальный вывод — чек-лист «что установлено / что дальше»

**Артефакт**: рабочий `install.sh`, который можно запустить на чистой машине.

**Тестирование**:
- macOS: запустить на свежем пользователе
- Ubuntu (WSL): запустить на чистом дистрибутиве
- Проверить: `opencode` запускается, видит MCP, читает `.docx`

---

## Этап 4. PowerShell-обёртка для Windows (1-2 часа)

**Задачи**:
1. Написать `install.ps1`:
   - Проверка WSL (`wsl --status`)
   - Если WSL нет — предложить `wsl --install` (с согласия пользователя)
   - Запуск `install.sh` внутри WSL через `wsl bash -c "..."`
   - Передача DeepSeek API Key (через переменную окружения, не через argv)
2. Протестировать на Windows 11 с WSL2

**Артефакт**: `install.ps1`, который делает то же, что `install.sh`, но из PowerShell.

**Риски**:
- Пути WSL (`/home/user/`) vs Windows (`C:\Users\...`) — конвертировать через `wslpath`
- Ключ в переменной окружения может попасть в логи PowerShell — использовать `Read-Host -AsSecureString`

---

## Этап 5. Тесты и документация (2-3 часа)

**Задачи**:
1. Написать `tests/test_install.sh`:
   - Проверка, что все бинарники на месте
   - Проверка, что `opencode.jsonc` валиден
   - Проверка, что MCP-серверы отвечают (через `opencode mcp list`)
2. Написать `README.md` для пользователя:
   - Что это
   - Как установить (одна команда)
   - Как использовать (примеры промптов)
   - Что делать, если что-то сломалось (FAQ)
3. Написать `CONTRIBUTING.md` для разработчиков (как добавить новый MCP)

**Артефакт**: тесты + документация.

---

## Этап 6. Первый релиз (1 час)

**Задачи**:
1. Создать GitHub Release с тегом `v0.1.0`
2. Приложить `install.sh` и `install.ps1`
3. Написать инструкцию: `curl -fsSL https://.../install.sh | bash`
4. Собрать обратную связь от 2-3 юристов (не разработчиков)

**Артефакт**: релиз, который можно рекомендовать коллегам.

---

## Что НЕ входит в v0.1.0 (backlog)

- ❌ Нативный Windows без WSL
- ❌ GUI для установщика
- ❌ Автоматическое решение капчи (DeepSeek vision + fallback)
- ❌ Telegram-бот для удалённого доступа
- ❌ Локальный RAG (LanceDB + RusLawOD)
- ❌ Интеграция с КонсультантПлюс (только ручной экспорт)
- ❌ Поддержка `court-case-monitor` для kad.arbitr (есть `ru-legal-mcp`)

---

## Порядок работы

1. Агент начинает с **Этапа 0** и идёт строго по порядку.
2. После каждого этапа — **коммит в git** с сообщением `feat: этап N — <что сделано>`.
3. Если на этапе возникает блокер (например, `sudrfscraper` не запускается) — **не переходить к следующему**, а написать в `NOTES.md` проблему и предложить решение.
4. Финальный тест — на **чистой машине** (не той, где шла разработка).

## Метрики успеха

- Установка занимает **< 15 минут** на чистой машине
- Пользователь **не вводит ни одной команды**, кроме `curl ... | bash` и API Key
- После установки агент **сразу** может:
  - Прочитать `.docx` из `~/knowledge_base/`
  - Найти статью ГК РФ через `ru-legal-mcp`
  - Запустить `run_sudrf_scrape` и получить JSON

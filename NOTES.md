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

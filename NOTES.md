# NOTES.md — проблемы и решения в ходе разработки

## Этап 0 (подготовка репозитория)

### 1. `ru-legal-mcp` отсутствует на PyPI

Проверка: `https://pypi.org/pypi/ru-legal-mcp/json` → **404**.

Команда `uvx ru-legal-mcp` из плана **не сработает** — пакета нет.
Найденные кандидаты на GitHub:

- `shodenis/Russian-Law-MCP` — MCP-сервер по федеральному законодательству РФ
- `AlsKozlov/ru-legal` — knowledge layer для российского права

**Решение**: разобраться на Этапе 2. Варианты — взять готовый Russian-Law-MCP
(установка из Git: `uv tool install git+https://github.com/...`) либо свой форк.
Не блокирует планы этапов 0–1, но влияет на строку в шаблоне конфига.

Статус: **открыто** (к Этапу 2).

### 2. Формат `opencode.jsonc`: `apiKey` лежит в `options`

В шаблоне из `plan.md` ключ указан как `provider.deepseek.apiKey`.
По официальной схеме `https://opencode.ai/config.json` правильный путь:
`provider.deepseek.options.apiKey`. Исправлено в `templates/opencode.jsonc.template`.

Также в шаблон добавлен `"model": "deepseek/DeepSeek-V4-Flash"` — чтобы агент
запускался «из коробки» без ручного выбора модели. К проверке на Этапе 2:
корректен ли API-id `deepseek-chat` и нужно ли вообще переопределять `models`.

Статус: **исправлено в шаблоне**, требует проверки на Этапе 2.

# CONTRIBUTING — для разработчиков установщика

Перед работой прочитайте `AGENTS.md`, `plan.md` и `docs/acceptance-criteria.md`.
Приёмка — по чек-листу (`docs/acceptance-criteria.md`, отчёт по форме J).

## Структура

```
install.sh                  # установщик (macOS/Linux/WSL)
install.ps1                 # Windows-обёртка (запускает install.sh в WSL2)
uninstall.sh                # удаление всех следов (G4)
templates/opencode.jsonc.template  # конфиг с плейсхолдерами
skills/source-locked-ru/    # скилл «только по источникам»
sudrf-scraper-mcp/          # наш MCP (обёртка над sudrfscraper)
tests/test_install.sh       # smoke-тест после установки
docs/                       # сценарий, рутина, критерии приёмки
NOTES.md                    # найденные грабли и решения (читать до отладки!)
```

## Правила

- **Никаких секретов в логах/stdout.** Ключи — только через `read -s` с `/dev/tty`
  или env (для тестов); в `install.log` их быть не может.
- **Идемпотентность**: повторный запуск `install.sh` не ломает систему.
- **Понятные ошибки**: «что случилось» и «как исправить», не просто `error`.
- **Чужие файлы не трогаем**: только `~/.config/opencode/` и `~/.local/share/legal-agent/`.
- **Платная инфраструктура запрещена** (исключение — бесплатные тарифы:
  api-fns.ru 100 запросов/метод).
- Новые компоненты ставятся **без sudo** (по возможности) и с проверкой,
  не установлены ли уже.

## Как добавить новый MCP-сервер

1. Проверьте, что сервер действительно бесплатный и запускается через `uvx`:
   `uvx --from <путь-или-пакет> python -c "import <модуль>"`.
2. Добавьте запись в `templates/opencode.jsonc.template` (с плейсхолдерами,
   если нужен ключ; `"enabled": true`).
3. Добавьте проверку в `install.sh` (`check_mcp_servers`) и в
   `tests/test_install.sh`.
4. Если сервер требует ключ: опциональный вопрос в `install.sh` (шаг «Ключи»),
   при пропуске — выключить сервер в конфиге (`"enabled": false`).
5. Обновите `README.md` (таблица «Что умеет агент»), `plan.md`, `NOTES.md`.
6. Проверьте: рендер конфига валиден, `opencode mcp list` показывает `connected`.

## Обновление sudrf-scraper-mcp

- Локальная проверка: `uvx --no-cache --from sudrf-scraper-mcp sudrf-scraper-mcp`
  (флаг `--no-cache` обязателен: `uvx` кэширует локальные сборки).
- После правок в коде сервера — прогнать smoke: tools/list через stdio,
  `check_sudrf_environment`, ошибки без установленного приложения.
- Известные грабли апстрима (geckodriver, https-миграция судов, блокер записи
  результатов) — `NOTES.md` пп. 6–8.

## Тестирование

- Локально без «чистой машины»: `HOME=$(mktemp -d) DEEPSEEK_KEY=sk-test bash install.sh`
  (изолированный HOME), затем `HOME=... bash tests/test_install.sh`.
- Тестовый прогон `install.ps1`: на macOS можно проверить синтаксис и guard
  через PowerShell 7 (`pwsh`): парсер `Parser::ParseFile` + запуск (ожидаем
  отказ «предназначен для Windows»).
- Полная приёмка — на чистой macOS 14+ и Ubuntu 22.04+ (WSL2).

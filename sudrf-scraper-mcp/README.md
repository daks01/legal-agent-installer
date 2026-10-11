# sudrf-scraper-mcp

MCP-сервер для сбора судебной практики судов общей юрисдикции РФ через
[SUDRF Scraper](https://github.com/tochno-st/sudrfscraper) — обёртка, которая
даёт AI-агенту инструменты «запусти сбор → проверь прогресс → забери JSON».

## Как это устроено

```
opencode (агент)
   │  MCP (stdio)
   ▼
sudrf-scraper-mcp (этот пакет)
   │  HTTP API на localhost:8080          фоновая JVM
   ▼                                      ┌──────────────────────┐
SUDRF Scraper (Spring Boot, run.sh) ──────┤ + Firefox WebDriver  │
   │                                      └──────────────────────┘
   ▼
<directory>/<project>/<project>.json   (JSON Lines — по делу на строку)
```

- Первый `run_sudrf_scrape` сам поднимает `run.sh` из `SUDRF_HOME`
  (по умолчанию `~/.local/share/legal-agent/sudrfscraper`), лог — `app.log`.
- Сбор асинхронный: инструмент возвращает ответ сразу после старта.
- Капчу вводит **человек** в браузере на `http://localhost:8080` — авторешение
  капчи вне scope v1.

## Требования

- Firefox (SUDRF Scraper использует Firefox WebDriver);
- распакованный релиз SUDRF Scraper в `SUDRF_HOME` (ставится установщиком
  legal-agent; вручную — с https://github.com/tochno-st/sudrfscraper/releases);
- Россиийский IP желателен: часть судов блокирует зарубежные адреса;
- релизы SUDRF Scraper — x64 (на Apple Silicon нужна Rosetta).

## Запуск и тестирование

```bash
# запуск сервера (stdio)
uvx --from . sudrf-scraper-mcp

# интерактивная проверка инструментов
npx @modelcontextprotocol/inspector uvx --from . sudrf-scraper-mcp
```

### Переменные окружения

| Переменная          | По умолчанию                                 | Смысл                          |
| ------------------- | -------------------------------------------- | ------------------------------ |
| `SUDRF_HOME`        | `~/.local/share/legal-agent/sudrfscraper`    | Папка распакованного релиза    |
| `SUDRF_PORT`        | `8080`                                       | Порт веб-интерфейса приложения |
| `SUDRF_FIREFOX_BIN` | авто (системный Firefox → сборка Playwright) | Явный путь к бинарнику Firefox |

### Нюансы релиза sudrfscraper (проверено на v0.3.0.3)

- В macOS-сборку положен **Linux-бинарник geckodriver** (баг упаковки автора).
  MCP это диагностирует (`geckodriver_compatible: false`); замена — скачать
  [официальный geckodriver](https://github.com/mozilla/geckodriver/releases)
  и положить в `src/main/resources/macOS/geckodriver`. `install.sh` делает это сам.
- Firefox можно не ставить системно: подходит сборка Playwright
  (`npx playwright install firefox`) — MCP находит её автоматически и передаёт
  JVM через `JAVA_TOOL_OPTIONS=-Dwebdriver.firefox.bin=...` при старте приложения.
- Для разработки запускай `uvx --no-cache --from . sudrf-scraper-mcp`: иначе
  `uvx` переиспользует закэшированную сборку и не видит правки во вложенных файлах.
- Сайты судов блокируют зарубежные IP: сбор из-за VPN/из-за границы даёт
  «Server error» по всем судам — нужен российский IP.

## Инструменты

| Инструмент                 | Что делает                                                        |
| -------------------------- | ----------------------------------------------------------------- |
| `check_sudrf_environment`  | Диагностика: установлен ли, есть ли Firefox, запущено ли, проблемы |
| `list_sudrf_regions`       | Коды регионов для параметра `regions` (86 значений)               |
| `run_sudrf_scrape`         | Запустить сбор (статья, тип дела, регионы, даты и т.д.)           |
| `get_sudrf_status`         | Прогресс: собрано записей, ждёт капчу, завершено ли                |
| `get_sudrf_results`        | Постранично прочитать JSON-выгрузку                               |
| `submit_sudrf_captcha`     | Отправить капчу текстом (если пользователь продиктовал)           |
| `stop_sudrf_scraper`       | Остановить приложение                                             |

## Ограничения v1 (осознанные)

- **Нет параметра `limit`** — в SUDRF Scraper его не существует; сужай выборку
  регионами, периодом и статьёй.
- **Капча — вручную** в браузере (авторешение — backlog).
- **Непрерывный прогресс через WebSocket** не реализован: статус и хвост
  `*_logs.log` вместо живого прогресс-бара.
- Нативный Windows не поддерживается (только WSL2).

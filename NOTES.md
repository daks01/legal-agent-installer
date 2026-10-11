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

### 5. E2E-тест на машине разработчика (2026-10-11) — пайплайн доказан

Проверено вживую: **opencode → MCP → приложение → geckodriver → Firefox →
запросы к sudrf.ru**. Что выяснилось:

- **Firefox из Playwright подходит**: `npx playwright install firefox` сработал
  с geckodriver (Marionette включён). MCP находит его автоматически и передаёт
  JVM `JAVA_TOOL_OPTIONS=-Dwebdriver.firefox.bin=<path>` при старте приложения.
  Системный Firefox не обязателен.
- **Баг релиза sudrfscraper v0.3.0.3**: в macOS-сборку положен Linux-бинарник
  geckodriver (ELF вместо Mach-O) — приложение из коробки на macOS не работает.
  Заменили на официальный geckodriver 0.37.1 (xattr снят). MCP диагностирует это
  (`geckodriver_compatible`), `install.sh` должен заменять автоматически.
- **uvx кэширует локальную сборку** и не видит правки во вложенных файлах:
  для разработки запускать `uvx --no-cache --from . sudrf-scraper-mcp`,
  иначе изменения не подхватываются.
- **Блокировка не-РФ IP**: при VPN-выходе в Хельсинки все суды отвечали 403,
  приложение писало `Server error`. С российского IP (Пермь) — суды отвечают 200.
- opencode в режиме `run` корректно вызывает MCP-инструменты; чтение чужих
  директорий (app.log) требует явного разрешения `external_directory` в конфиге.

### 6. Миграция сайтов судов на https + смена доменов (критично)

Сайты судов перешли на https и сменили канонические домены:
`anadyr--chao.sudrf.ru` → `anadyr.chao.sudrf.ru` (`--` в первой части хоста → `.`),
http-запросы отвечают 302/301. Релиз sudrfscraper (дек. 2024) этого не умеет:

- старый конфиг (`http://<host>--<reg>`): список страниц падал (`Server error`);
- https-конфиг: список работал, но карточки дел падали — в `Connector` баг:
  `searchString.replace("http://","")` не срезает `https://`, JVM шлёт
  невалидный `Host: https://...` → 404.

**Обход (проверен)**: в конфигах судов (`src/main/resources/config/config_*.json`)
заменить домены на канонические, но **оставить `http://`**: тогда и список
(сам снимает и `http://`, и `https://`), и карточки (снимает только `http://`)
получают корректный `Host`, а редиректы http→https HttpClient отрабатывает.
Скрипт патча — `install.sh` (Этап 3) должен применять его при установке.

### 7. БЛОКЕР: приложение находит дела, но не сохраняет их (баг апстрима)

С включённым патчем конфигов (п. 6) приложение реально собирает практику:
по Чукотскому АО (ст. 158 УК, р-е суды, 2024) **найдено 57 дел** по всем 7 судам,
тексты решений скачивались. Но JSON-выгрузка так и не заполняется — воспроизведено
**4 прогона из 4**.

Что видно по логам и websocket-монитору:

1. через ~2 сек после старта в websocket прилетают два
   `Exception occurred: [null]` (у скрытых исключений message=null — вероятно NPE)
   и `Exception occurred: [java.lang.InterruptedException]`;
2. приложение перехватывает все необработанные исключения кастомным
   обработчиком (`Starter.SUDRFErrorHandler`), который при исключении в
   не-pool потоке вызывает `mainThread.interrupt()` — поток сбора получает
   `InterruptedException` и преждевременно вызывает `end()`;
3. `end()` успевает закрыть поток-писатель (`_meta.json` пишется с
   `string_count: -1`), но `sumItUp()`/`_summary.txt` не выполняется;
4. courts продолжают собирать данные (57 дел), но писать их уже некому —
   JSON остаётся пустым.

Ошибки приложение никуда не логирует (только в websocket без клиентов) —
поэтому раньше не находились в логах.

**Возможные решения (по возрастанию сложности)**:

- **a. Тест на чистого Linux/WSL** — DoD всё равно требует проверки на Ubuntu;
  баг может быть macOS-специфичным (сборка macOS у автора явно менее тестируемая:
  см. geckodriver). Быстрый способ проверить — машина с WSL2.
- **b. Патч JAR** — установить JDK, пересобрать 1-2 класса (`Starter`)
  с защитой: не вызывать `update(null)`, не прерывать поток сбора на «тихих»
  ошибках, обернуть писатель от `Throwable`. ~1 час работы + риск.
- **c. Форк sudrfscraper** с фиксами — правильное долгосрочное решение,
  но это уже отдельный проект.

Статус: **MCP готов и проверен**, пайплайн сбора доказан (дела находятся),
сохранение результатов блокировано багом апстрима — нужно решение заказчика.

### 8. Пара мелких фиксов по итогам E2E

- В `run_sudrf_scrape` в `chosenDirectory` добавлен трейлинг-слэш: приложение
  склеивает `"<directory><project>/"`, без слэша выгрузка падала в соседнюю папку
  с именем `court_practiceverify-...`.
- `finished` теперь определяется только по `<project>_summary.txt`:
  `_meta.json` пишется приложением раньше (в середине сбора) — по нему судить нельзя.

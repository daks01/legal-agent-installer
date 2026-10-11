"""sudrf-scraper-mcp — MCP-обёртка над SUDRF Scraper.

SUDRF Scraper (https://github.com/tochno-st/sudrfscraper) — Spring Boot
приложение с локальным веб-интерфейсом на http://localhost:8080. Оно ищет
дела и тексты решений на сайтах судов общей юрисдикции (sudrf.ru).

Как это работает вместе:

1. Установщик legal-agent кладёт распакованный релиз SUDRF Scraper в
   ``SUDRF_HOME`` (по умолчанию ``~/.local/share/legal-agent/sudrfscraper``).
2. Первый вызов ``run_sudrf_scrape`` поднимает ``run.sh`` этого релиза
   (фоновый процесс, лог в ``<SUDRF_HOME>/app.log``).
3. Дальше MCP общается с приложением по его HTTP API: ``/check_request`` →
   ``/init`` → результаты в JSONL-файле.

Капчу вводит человек в браузере на http://localhost:8080 — авторешение капчи
вне scope v1. Ограничения SUDRF Scraper (нет параметра limit, нужен Firefox,
рекомендуется российский IP) описаны в README.
"""

from __future__ import annotations

import datetime as dt
import json
import logging
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Annotated, Any, Literal

import httpx
from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import Field

logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("sudrf-scraper-mcp")

DEFAULT_HOME = Path.home() / ".local" / "share" / "legal-agent" / "sudrfscraper"
DEFAULT_PORT = 8080
DEFAULT_RESULTS_DIR = "~/knowledge_base/court_practice"
APP_START_TIMEOUT_SEC = 90

SUDRF_RELEASES_URL = "https://github.com/tochno-st/sudrfscraper/releases"
FIREFOX_URL = "https://www.mozilla.org/firefox/new/"

CaseType = Literal["criminal", "admin", "cas", "material_proceeding", "civil"]
FilterMode = Literal["soft", "strict"]

# Коды регионов — значения select#regions из UI SUDRF Scraper (v0.3.0.3).
REGIONS: dict[str, str] = {
    "all": "Все регионы",
    "1": "Республика Адыгея (Адыгея)",
    "4": "Республика Алтай",
    "2": "Республика Башкортостан",
    "3": "Республика Бурятия",
    "5": "Республика Дагестан",
    "6": "Республика Ингушетия",
    "7": "Кабардино-Балкарская Республика",
    "8": "Республика Калмыкия",
    "9": "Карачаево-Черкесская Республика",
    "10": "Республика Карелия",
    "11": "Республика Коми",
    "82": "Республика Крым",
    "12": "Республика Марий Эл",
    "13": "Республика Мордовия",
    "14": "Республика Саха (Якутия)",
    "15": "Республика Северная Осетия — Алания",
    "16": "Республика Татарстан (Татарстан)",
    "17": "Республика Тыва",
    "18": "Удмуртская Республика",
    "19": "Республика Хакасия",
    "20": "Чеченская Республика",
    "21": "Чувашская Республика — Чувашия",
    "22": "Алтайский край",
    "75": "Забайкальский край",
    "41": "Камчатский край",
    "23": "Краснодарский край",
    "24": "Красноярский край",
    "59": "Пермский край",
    "25": "Приморский край",
    "26": "Ставропольский край",
    "27": "Хабаровский край",
    "28": "Амурская область",
    "29": "Архангельская область",
    "30": "Астраханская область",
    "31": "Белгородская область",
    "32": "Брянская область",
    "33": "Владимирская область",
    "34": "Волгоградская область",
    "35": "Вологодская область",
    "36": "Воронежская область",
    "37": "Ивановская область",
    "38": "Иркутская область",
    "39": "Калининградская область",
    "40": "Калужская область",
    "42": "Кемеровская область",
    "43": "Кировская область",
    "44": "Костромская область",
    "45": "Курганская область",
    "46": "Курская область",
    "47": "Ленинградская область",
    "48": "Липецкая область",
    "49": "Магаданская область",
    "50": "Московская область",
    "51": "Мурманская область",
    "52": "Нижегородская область",
    "53": "Новгородская область",
    "54": "Новосибирская область",
    "55": "Омская область",
    "56": "Оренбургская область",
    "57": "Орловская область",
    "58": "Пензенская область",
    "60": "Псковская область",
    "61": "Ростовская область",
    "62": "Рязанская область",
    "63": "Самарская область",
    "64": "Саратовская область",
    "65": "Сахалинская область",
    "66": "Свердловская область",
    "67": "Смоленская область",
    "68": "Тамбовская область",
    "69": "Тверская область",
    "70": "Томская область",
    "71": "Тульская область",
    "72": "Тюменская область",
    "73": "Ульяновская область",
    "74": "Челябинская область",
    "76": "Ярославская область",
    "77": "Москва",
    "78": "Санкт-Петербург",
    "92": "Севастополь",
    "79": "Еврейская автономная область",
    "83": "Ненецкий автономный округ",
    "86": "Ханты-Мансийский автономный округ",
    "87": "Чукотский автономный округ",
    "89": "Ямало-Ненецкий автономный округ",
}

_LEVELS = ("region", "district", "garrison", "mosgorsud")
_INSTANCES = ("first", "appellation", "cassation")
_DATE_FORMATS = ("%d/%m/%Y", "%d.%m.%Y", "%Y-%m-%d")

_client = httpx.Client(timeout=httpx.Timeout(30.0, connect=5.0), follow_redirects=True)


def _app_home() -> Path:
    return Path(os.getenv("SUDRF_HOME", str(DEFAULT_HOME))).expanduser()


def _app_port() -> int:
    return int(os.getenv("SUDRF_PORT", str(DEFAULT_PORT)))


def _base_url() -> str:
    return f"http://localhost:{_app_port()}"


def _find_run_sh(home: Path) -> Path | None:
    direct = home / "run.sh"
    if direct.is_file():
        return direct
    for nested in sorted(home.glob("*/run.sh")):
        return nested
    return None


def _find_bundled_java(home: Path) -> Path | None:
    for pattern in ("*/jre/bin/java", "jre/bin/java", "*/jre/bin/java.exe", "jre/bin/java.exe"):
        for candidate in sorted(home.glob(pattern)):
            return candidate
    return None


def _find_firefox() -> str | None:
    if sys.platform == "darwin":
        app = Path("/Applications/Firefox.app")
        if app.is_dir():
            return str(app)
    for name in ("firefox", "firefox-esr"):
        if found := shutil.which(name):
            return found
    return None


def _app_responds() -> bool:
    try:
        return _client.get(_base_url() + "/").status_code == 200
    except httpx.HTTPError:
        return False


def _port_open() -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.5)
        return sock.connect_ex(("127.0.0.1", _app_port())) == 0


def _tail(path: Path, lines: int) -> list[str]:
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    return text.splitlines()[-lines:]


def _count_jsonl_lines(path: Path) -> int:
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            return sum(1 for line in handle if line.strip())
    except OSError:
        return 0


def _get(path: str) -> httpx.Response:
    try:
        return _client.get(_base_url() + path)
    except httpx.HTTPError as exc:
        raise ToolError(
            f"Не могу подключиться к SUDRF Scraper ({_base_url()}{path}): {exc}. "
            f"Проверь, что приложение запущено — check_sudrf_environment()."
        ) from exc


def _post_json(
    path: str, payload: dict[str, Any], headers: dict[str, str] | None = None
) -> httpx.Response:
    try:
        return _client.post(_base_url() + path, json=payload, headers=headers or {})
    except httpx.HTTPError as exc:
        raise ToolError(
            f"Не могу подключиться к SUDRF Scraper ({_base_url()}{path}): {exc}. "
            f"Проверь, что приложение запущено — check_sudrf_environment()."
        ) from exc


def _require_installation() -> tuple[Path, Path]:
    home = _app_home()
    if not home.is_dir() or not any(home.iterdir()):
        raise ToolError(
            f"SUDRF Scraper не установлен: папка {home} пуста или отсутствует.\n"
            f"Что делать: запусти установщик legal-agent (install.sh) — он скачает последний релиз "
            f"с {SUDRF_RELEASES_URL} и распакует в {home}. "
            f"Либо укажи существующую папку: SUDRF_HOME=/путь/до/sudrfscraper."
        )
    run_sh = _find_run_sh(home)
    if run_sh is None:
        raise ToolError(
            f"В {home} нет run.sh — папка не похожа на распакованный релиз SUDRF Scraper. "
            f"Переустанови приложение через install.sh."
        )
    if _find_firefox() is None:
        raise ToolError(
            "Не найден браузер Firefox — SUDRF Scraper использует Firefox WebDriver.\n"
            f"Что делать: установи Firefox ({FIREFOX_URL}) и повтори вызов."
        )
    return home, run_sh


def _ensure_app_running(home: Path, run_sh: Path, auto_start: bool) -> None:
    if _app_responds():
        return
    if not auto_start:
        raise ToolError(
            f"Приложение SUDRF Scraper не запущено (порт {_app_port()}). "
            f"Запусти его командой: {run_sh} — или повтори вызов с auto_start=true."
        )
    log_path = home / "app.log"
    logger.info("Starting SUDRF Scraper: %s (cwd=%s)", run_sh, home)
    with log_path.open("ab") as log:
        subprocess.Popen(
            ["/bin/sh", str(run_sh)],
            cwd=str(home),
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    deadline = time.monotonic() + APP_START_TIMEOUT_SEC
    while time.monotonic() < deadline:
        if _app_responds():
            return
        time.sleep(1)
    tail = "\n".join(_tail(log_path, 20)) or "(лог пуст)"
    raise ToolError(
        f"SUDRF Scraper не поднялся за {APP_START_TIMEOUT_SEC} сек ({_base_url()}).\n"
        f"Последние строки {log_path}:\n{tail}\n"
        "Частые причины: macOS блокирует JRE из архива (Системные настройки → "
        "Защита и безопасность → «Разрешить»); порт занят другой программой; "
        "не хватает прав на run.sh."
    )


def _normalize_date(value: str | None, field_name: str) -> str:
    if value is None or not value.strip():
        return ""
    for fmt in _DATE_FORMATS:
        try:
            return dt.datetime.strptime(value.strip(), fmt).strftime("%d/%m/%Y")
        except ValueError:
            continue
    raise ToolError(
        f"{field_name}={value!r}: неверный формат даты. Используй ДД.ММ.ГГГГ (например, 11.10.2026)."
    )


def _normalize_choice_list(
    values: list[str] | None,
    allowed: tuple[str, ...],
    field_name: str,
) -> list[str]:
    if not values or [v.lower() for v in values] == ["all"]:
        return []
    normalized = []
    for value in values:
        low = value.strip().lower()
        if low not in allowed:
            raise ToolError(
                f"{field_name}: недопустимое значение {value!r}. Допустимые: {', '.join(allowed)}."
            )
        normalized.append(low)
    return normalized


def _normalize_regions(regions: list[str] | None) -> list[str]:
    if not regions or [r.strip().lower() for r in regions] == ["all"]:
        return []
    normalized = []
    for region in regions:
        code = region.strip()
        if code not in REGIONS or code == "all":
            raise ToolError(
                f"regions: неизвестный код региона {region!r}. "
                f"Полный список — list_sudrf_regions()."
            )
        normalized.append(code)
    return normalized


def _build_article(
    case_type: CaseType,
    article: str | None,
    article_part: int | None,
    article_sub_part: int | None,
    article_letter: str | None,
    codex_part: str | None,
    mosgorsud_code: str | None,
) -> dict[str, str]:
    if case_type == "criminal":
        result = {"field": "CRIMINAL", "article": "", "subArticle": "", "part": "", "letter": ""}
        if article:
            head, _, sub = article.partition(".")
            if not head.isdigit() or (sub and not sub.isdigit()):
                raise ToolError(
                    f"article={article!r}: для УК укажи номер статьи, напр. '158' или '158.1' (статья.подстатья)."
                )
            result["article"] = head
            result["subArticle"] = sub
        elif article_part is not None or article_letter:
            raise ToolError("article_part/article_letter можно указывать только вместе с article.")
        if article_part is not None:
            result["part"] = str(article_part)
        if article_letter:
            if len(article_letter) != 1:
                raise ToolError("article_letter: буква статьи УК — ровно один символ, напр. 'а'.")
            result["letter"] = article_letter
        return result

    if case_type == "admin":
        result = {
            "field": "ADMIN",
            "chapter": "",
            "article": "",
            "subArticle": "",
            "part": "",
            "subPart": "",
        }
        if article:
            parts = article.split(".")
            if len(parts) < 2 or not all(part.isdigit() for part in parts):
                raise ToolError(
                    f"article={article!r}: для КоАП укажи 'глава.статья', напр. '12.8' или '12.8.3' "
                    f"(третий компонент — подстатья)."
                )
            result["chapter"], result["article"] = parts[0], parts[1]
            if len(parts) > 2:
                result["subArticle"] = parts[2]
        if article_part is not None:
            if not article:
                raise ToolError(
                    "article_part можно указывать только вместе с article ('глава.статья')."
                )
            result["part"] = str(article_part)
        if article_sub_part is not None:
            if not article:
                raise ToolError("article_sub_part можно указывать только вместе с article.")
            result["subPart"] = str(article_sub_part)
        return result

    if case_type in ("cas", "civil", "material_proceeding"):
        field = {"cas": "CAS", "civil": "CIVIL", "material_proceeding": "MATERIAL_PROCEEDING"}[
            case_type
        ]
        key = "partOfUPK" if case_type == "material_proceeding" else "partOfCas"
        result = {
            "field": field,
            key: (codex_part or "").strip(),
            "mosgorsudCode": (mosgorsud_code or "").strip(),
        }
        if not result[key] and result["mosgorsudCode"]:
            raise ToolError("mosgorsud_code можно указывать только вместе с codex_part.")
        return result

    raise ToolError(f"case_type={case_type!r} не поддерживается.")


mcp = FastMCP(
    name="sudrf-scraper",
    instructions=(
        "sudrf-scraper — сбор дел и текстов решений судов общей юрисдикции РФ (sudrf.ru) "
        "через приложение SUDRF Scraper. Порядок работы: run_sudrf_scrape() запускает сбор; "
        "капчу пользователь вводит в браузере на http://localhost:8080 (сообщи ему, если сбор встал); "
        "прогресс — get_sudrf_status(); результат — get_sudrf_results(). "
        "У приложения нет параметра limit: сужай поиск регионом, периодом и статьёй."
    ),
)


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def check_sudrf_environment() -> dict[str, Any]:
    """Проверить готовность окружения для SUDRF Scraper.

    Возвращает пути, наличие Firefox, встроенной Java, запущено ли приложение,
    и список проблем с инструкциями по исправлению. Вызывай первым, если
    run_sudrf_scrape вернул ошибку окружения.
    """
    home = _app_home()
    run_sh = _find_run_sh(home)
    firefox = _find_firefox()
    bundled_java = _find_bundled_java(home)
    app_running = _app_responds()

    problems: list[str] = []
    if run_sh is None:
        problems.append(
            f"SUDRF Scraper не установлен в {home}. Запусти install.sh или скачай релиз с {SUDRF_RELEASES_URL}."
        )
    if firefox is None:
        problems.append(f"Firefox не найден. Установи его: {FIREFOX_URL}")
    if run_sh is not None and bundled_java is None and shutil.which("java") is None:
        problems.append(
            "Не найдена ни встроенная JRE (папка jre/ внутри SUDRF Scraper), ни системная Java. "
            "Переустанови SUDRF Scraper из официального релиза."
        )
    if run_sh is not None and not app_running and _port_open():
        problems.append(
            f"Порт {_app_port()} занят другим приложением, а SUDRF Scraper не отвечает. "
            "Останови чужой процесс на этом порту или задай другой SUDRF_PORT."
        )
    if run_sh is not None and not app_running:
        problems.append(
            f"Приложение сейчас не запущено — это нормально. Оно поднимется автоматически "
            f"при вызове run_sudrf_scrape (лог: {home / 'app.log'})."
        )

    return {
        "app_home": str(home),
        "app_port": _app_port(),
        "installed": run_sh is not None,
        "run_sh": str(run_sh) if run_sh else None,
        "firefox": firefox,
        "bundled_java": str(bundled_java) if bundled_java else None,
        "system_java": shutil.which("java"),
        "app_running": app_running,
        "platform": sys.platform,
        "problems": problems,
    }


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def list_sudrf_regions() -> dict[str, str]:
    """Список регионов РФ для параметра regions (код → название).

    Используй, когда юрист называет регион словами («Татарстан», «Москва»),
    а инструменту нужен числовой код.
    """
    return REGIONS


@mcp.tool(annotations={"readOnlyHint": False, "openWorldHint": True})
def run_sudrf_scrape(
    article: Annotated[
        str | None,
        Field(
            description=(
                "Статья. УК: '158', '158.1'. КоАП: '12.8' (глава.статья), '12.8.3'. "
                "Можно не указывать — поиск по всем делам типа (не рекомендуется для admin/civil)."
            )
        ),
    ] = None,
    case_type: Annotated[
        CaseType,
        Field(
            description=(
                "Тип производства: criminal — уголовное (УК), admin — об административных "
                "правонарушениях (КоАП), cas — административное (КАС), material_proceeding — "
                "производства по материалам, civil — гражданское (ГПК/ГК)."
            )
        ),
    ] = "criminal",
    project_name: Annotated[
        str | None,
        Field(
            description="Имя выгрузки (латиница/цифры/дефис). По умолчанию sudrf-ГГГГММДД-ЧЧММСС."
        ),
    ] = None,
    directory: Annotated[
        str,
        Field(description="Папка результатов. По умолчанию ~/knowledge_base/court_practice."),
    ] = DEFAULT_RESULTS_DIR,
    regions: Annotated[
        list[str] | None,
        Field(
            description=(
                "Коды регионов из list_sudrf_regions(), напр. ['77', '50']. "
                "None или ['all'] — все регионы (долго)."
            )
        ),
    ] = None,
    levels: Annotated[
        list[str] | None,
        Field(description="Уровни судов: region, district, garrison, mosgorsud. None — все."),
    ] = None,
    instances: Annotated[
        list[str] | None,
        Field(description="Инстанции: first, appellation, cassation. По умолчанию ['first']."),
    ] = None,
    date_from: Annotated[
        str | None,
        Field(description="Период рассмотрения «с» (ДД.ММ.ГГГГ). Пусто — без ограничения."),
    ] = None,
    date_to: Annotated[
        str | None, Field(description="Период рассмотрения «по» (ДД.ММ.ГГГГ).")
    ] = None,
    entry_date_from: Annotated[
        str | None, Field(description="Период поступления дела в суд «с» (ДД.ММ.ГГГГ).")
    ] = None,
    entry_date_to: Annotated[
        str | None, Field(description="Период поступления дела в суд «по» (ДД.ММ.ГГГГ).")
    ] = None,
    text: Annotated[
        str | None,
        Field(
            description=(
                "Поиск по тексту решения. Осторожно: многие суды не поддерживают — "
                "комбинируй с article и regions."
            )
        ),
    ] = None,
    filter_mode: Annotated[
        FilterMode,
        Field(description="soft — собирать подстатьи указанной статьи; strict — только точную."),
    ] = "soft",
    continue_previous: Annotated[
        bool, Field(description="Продолжить предыдущий сбор (то же имя проекта и папка).")
    ] = False,
    article_part: Annotated[
        int | None, Field(description="Часть статьи (УК/КоАП), число. Вместе с article.")
    ] = None,
    article_sub_part: Annotated[
        int | None, Field(description="Подчасть (только КоАП). Вместе с article.")
    ] = None,
    article_letter: Annotated[
        str | None, Field(description="Буква статьи УК — один символ, напр. 'а'. Вместе с article.")
    ] = None,
    codex_part: Annotated[
        str | None,
        Field(
            description=(
                "Для cas/civil — пункт кодекса (partOfCas); для material_proceeding — часть УПК "
                "(partOfUPK). Строка как в законе."
            )
        ),
    ] = None,
    mosgorsud_code: Annotated[
        str | None,
        Field(description="Код Мосгорсуда (cas/civil/material_proceeding, вместе с codex_part)."),
    ] = None,
    auto_start: Annotated[
        bool, Field(description="Автоматически запустить приложение, если оно не запущено.")
    ] = True,
) -> dict[str, Any]:
    """Запустить сбор судебной практики с сайтов судов (sudrf.ru).

    Сбор асинхронный: тул возвращает статус сразу после старта. Прогресс —
    get_sudrf_status(), результаты — get_sudrf_results(). Если на сайте суда
    появится капча, сбор приостановится — попроси пользователя ввести капчу
    по адресу http://localhost:8080. Параметра limit у SUDRF Scraper нет:
    сужай выборку регионами, периодом и статьёй.
    """
    home, run_sh = _require_installation()
    _ensure_app_running(home, run_sh, auto_start)

    if not project_name:
        project_name = f"sudrf-{dt.datetime.now():%Y%m%d-%H%M%S}"
    project_name = project_name.strip()
    if not project_name or "/" in project_name or "\\" in project_name:
        raise ToolError("project_name: допустимы латиница, цифры и дефис, без слэшей.")

    results_root = Path(directory).expanduser()
    results_root.mkdir(parents=True, exist_ok=True)

    article_obj = _build_article(
        case_type,
        article,
        article_part,
        article_sub_part,
        article_letter,
        codex_part,
        mosgorsud_code,
    )
    levels_norm = _normalize_choice_list(levels, _LEVELS, "levels")
    instances_norm = _normalize_choice_list(instances, _INSTANCES, "instances") or ["first"]

    payload = {
        "article": article_obj,
        "meta": {
            "chosenDirectory": str(results_root),
            "regions": _normalize_regions(regions),
            "levels": [level.upper() for level in levels_norm],
            "name": project_name,
            "filterMode": filter_mode,
            "needToContinue": continue_previous,
        },
        "instances": [instance.upper() for instance in instances_norm],
        "chosenDump": "JSON",
        "field": article_obj["field"],
        "connectionInf": None,
        "startDate": _normalize_date(date_from, "date_from"),
        "endDate": _normalize_date(date_to, "date_to"),
        "entryStartDate": _normalize_date(entry_date_from, "entry_date_from"),
        "entryEndDate": _normalize_date(entry_date_to, "entry_date_to"),
        "text": (text or "").strip(),
    }

    response = _post_json("/check_request", payload, headers={"Selected-Language": "ru"})
    if response.status_code != 200:
        raise ToolError(
            f"SUDRF Scraper отклонил параметры поиска (HTTP {response.status_code}): {response.text.strip()}"
        )

    init_response = _get("/init")
    if init_response.status_code != 200:
        raise ToolError(
            f"Не удалось запустить сбор (HTTP {init_response.status_code}): {init_response.text.strip()}"
        )
    logger.info(
        "Scraping started: project=%s case_type=%s article=%s", project_name, case_type, article
    )

    results_dir = results_root / project_name
    return {
        "status": "started",
        "project_name": project_name,
        "results_directory": str(results_dir),
        "output_file": str(results_dir / f"{project_name}.json"),
        "ui_url": f"{_base_url()}/scraping",
        "message": (
            "Сбор запущен. Если на сайте суда появится капча, сбор приостановится — "
            f"введи её в браузере: {_base_url()}/scraping. "
            "Прогресс: get_sudrf_status(project_name=..., directory=...). "
            "Результаты: get_sudrf_results(project_name=..., directory=...)."
        ),
    }


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def get_sudrf_status(
    project_name: Annotated[
        str | None, Field(description="Имя отслеживаемой выгрузки (необязательно).")
    ] = None,
    directory: Annotated[
        str, Field(description="Папка результатов, та же, что в run_sudrf_scrape.")
    ] = DEFAULT_RESULTS_DIR,
) -> dict[str, Any]:
    """Статус SUDRF Scraper: запущено ли приложение, идёт ли сбор, сколько собрано.

    Возвращает: app_running, scraping_in_progress, records_collected (строк в
    JSON-выгрузке), finished (сбор завершён), last_log_lines. Используй для
    периодического опроса, пока идёт сбор.
    """
    status: dict[str, Any] = {
        "app_running": _app_responds(),
        "port": _app_port(),
        "ui_url": f"{_base_url()}/",
    }
    if not status["app_running"]:
        status["message"] = (
            "Приложение не запущено. Оно поднимется автоматически при следующем run_sudrf_scrape."
        )
        return status

    try:
        status["scraping_in_progress"] = 'id="captchaImage"' in _get("/scraping").text
    except ToolError:
        status["scraping_in_progress"] = None

    if project_name:
        results_dir = Path(directory).expanduser() / project_name
        json_file = results_dir / f"{project_name}.json"
        status["results_directory"] = str(results_dir)
        status["output_file"] = str(json_file)
        if json_file.exists():
            status["records_collected"] = _count_jsonl_lines(json_file)
        status["finished"] = (results_dir / f"{project_name}_summary.txt").exists() or (
            results_dir / f"{project_name}_meta.json"
        ).exists()
        if results_dir.exists():
            status["files"] = sorted(path.name for path in results_dir.glob(f"{project_name}*"))
        status["last_log_lines"] = _tail(results_dir / f"{project_name}_logs.log", 15)
    return status


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def get_sudrf_results(
    project_name: Annotated[str, Field(description="Имя выгрузки из run_sudrf_scrape.")],
    directory: Annotated[
        str, Field(description="Папка результатов, та же, что в run_sudrf_scrape.")
    ] = DEFAULT_RESULTS_DIR,
    offset: Annotated[int, Field(description="Пропустить первые N записей.", ge=0)] = 0,
    limit: Annotated[
        int, Field(description="Сколько записей вернуть (макс. 200).", ge=1, le=200)
    ] = 20,
) -> dict[str, Any]:
    """Прочитать собранные дела из JSON-выгрузки (постранично).

    Каждое дело — отдельный JSON-объект: номер, суд, даты, стороны, ссылки
    на тексты решений. Если файл ещё не создан — сбор не стартовал или упал:
    проверь get_sudrf_status().
    """
    results_dir = Path(directory).expanduser() / project_name
    json_file = results_dir / f"{project_name}.json"
    if not json_file.exists():
        raise ToolError(
            f"Файл выгрузки ещё не создан: {json_file}. "
            "Проверь get_sudrf_status(project_name=..., directory=...) — возможно, сбор ещё идёт, "
            "ждёт ввода капчи или не запускался."
        )

    records: list[dict[str, Any]] = []
    with json_file.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                logger.warning("Skipping malformed JSON line in %s", json_file)

    finished = (results_dir / f"{project_name}_summary.txt").exists() or (
        results_dir / f"{project_name}_meta.json"
    ).exists()
    page = records[offset : offset + limit]
    return {
        "status": "ok",
        "project_name": project_name,
        "output_file": str(json_file),
        "total": len(records),
        "offset": offset,
        "returned": len(page),
        "finished": finished,
        "records": page,
        "files": sorted(path.name for path in results_dir.glob(f"{project_name}*")),
    }


@mcp.tool(annotations={"readOnlyHint": False})
def submit_sudrf_captcha(
    captcha: Annotated[str, Field(description="Текст капчи, как его видит пользователь.")],
) -> dict[str, Any]:
    """Отправить капчу в приложение (когда пользователь продиктовал её текстом).

    Обычно проще ввести капчу самому в браузере: http://localhost:8080/scraping.
    """
    if not captcha.strip():
        raise ToolError("captcha: пустая строка.")
    response = _post_json("/submit_captcha", {"captcha": captcha.strip()})
    if response.status_code != 200:
        raise ToolError(
            f"Капча не принята (HTTP {response.status_code}): {response.text.strip()}. "
            f"Проверь, что сбор сейчас ждёт капчу: {_base_url()}/scraping"
        )
    return {"status": "submitted", "message": "Капча отправлена."}


@mcp.tool(annotations={"readOnlyHint": False})
def stop_sudrf_scraper() -> dict[str, Any]:
    """Остановить приложение SUDRF Scraper (завершит текущий сбор, если он идёт)."""
    response = _get("/finish")
    if response.status_code != 200:
        raise ToolError(f"Не удалось остановить приложение (HTTP {response.status_code}).")
    return {"status": "stopped", "message": "SUDRF Scraper остановлен."}


def main() -> None:
    logger.info("Starting sudrf-scraper-mcp — app_home=%s port=%d", _app_home(), _app_port())
    mcp.run()


if __name__ == "__main__":
    main()

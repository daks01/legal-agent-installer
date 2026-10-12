"""laws-mcp — локальная база российского права (law7-lite) без Docker.

Данные: официальные тексты (ГК РФ ст. 1259 — не объект авторских прав), собраны
проектом law7 (AGPL-3.0) из pravo.gov.ru и восстановлены в SQLite нашими скриптами
(laws/build/). Снапшот: см. laws_status().
"""

from __future__ import annotations

import json
import logging
import os
import re
import sqlite3
import sys
import time
import urllib.request
from pathlib import Path
from typing import Annotated, Any

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from pydantic import Field

logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("laws-mcp")

DEFAULT_DIR = Path.home() / ".local" / "share" / "legal-agent" / "law7-lite"
CORE_DB = Path(os.getenv("LAWS_DB", str(DEFAULT_DIR / "laws.db")))
PUBLICATIONS_DB = Path(os.getenv("LAWS_PUBLICATIONS_DB", str(DEFAULT_DIR / "laws-publications.db")))
RUSLAW_DB = Path(os.getenv("LAWS_RUSLAW_DB", str(DEFAULT_DIR / "ruslaw.db")))

LAW7_BACKUP_DOC = "https://raw.githubusercontent.com/mikhashev/law7/main/docs/BACKUP_RESTORE.md"
UPDATE_CACHE = DEFAULT_DIR / ".update_check.json"
UPDATE_CACHE_TTL = 24 * 3600  # сутки

CODE_NAMES = {
    "KONST_RF": "Конституция РФ",
    "GK_RF": "ГК РФ, часть первая",
    "GK_RF_2": "ГК РФ, часть вторая",
    "GK_RF_3": "ГК РФ, часть третья",
    "GK_RF_4": "ГК РФ, часть четвёртая",
    "UK_RF": "УК РФ",
    "NK_RF": "НК РФ, часть первая",
    "NK_RF_2": "НК РФ, часть вторая",
    "TK_RF": "ТК РФ",
    "GPK_RF": "ГПК РФ",
    "APK_RF": "АПК РФ",
    "UPK_RF": "УПК РФ",
    "KoAP_RF": "КоАП РФ",
    "ZhK_RF": "ЖК РФ",
    "ZK_RF": "ЗК РФ",
    "LK_RF": "ЛК РФ",
    "VK_RF": "Воздушный кодекс РФ",
    "VZK_RF": "Водный кодекс РФ",
    "VDK_RF": "Водный кодекс РФ",
    "SK_RF": "Семейный кодекс РФ",
    "BK_RF": "Бюджетный кодекс РФ",
    "GRK_RF": "Градостроительный кодекс РФ",
    "UIK_RF": "УИК РФ",
    "KAS_RF": "КАС РФ (не загружен в снапшот)",
}


def _open_core() -> sqlite3.Connection:
    if not CORE_DB.exists():
        raise ToolError(
            f"База законов не установлена: {CORE_DB}.\n"
            "Установите: bash install.sh (скачает laws.db) — или укажите LAWS_DB=/путь/к/laws.db"
        )
    return sqlite3.connect(f"file:{CORE_DB}?mode=ro", uri=True)


def _open_ruslaw() -> sqlite3.Connection:
    if not RUSLAW_DB.exists():
        raise ToolError(
            "База RusLawOD (полный корпус законов 1991–2026) не установлена.\n"
            "Опциональный компонент (~2 ГБ): bash update-laws.sh --with-ruslaw "
            "(или install.sh --with-ruslaw)."
        )
    return sqlite3.connect(f"file:{RUSLAW_DB}?mode=ro", uri=True)


def _open_publications() -> sqlite3.Connection:
    if not PUBLICATIONS_DB.exists():
        raise ToolError(
            "База публикаций (1,1 млн актов pravo.gov.ru) не установлена.\n"
            "Это опциональный компонент: bash install.sh --with-publications (≈160 МБ)."
        )
    return sqlite3.connect(f"file:{PUBLICATIONS_DB}?mode=ro", uri=True)


def _fts_query(query: str, max_tokens: int = 8) -> str:
    """Собирает безопасный FTS5-запрос: все слова как префиксы через AND."""
    tokens = re.findall(r"[0-9A-Za-zА-Яа-яЁё]+", query)[:max_tokens]
    if not tokens:
        raise ToolError("search: пустой запрос.")
    return " AND ".join(f"{token}*" for token in tokens)


def _meta(con: sqlite3.Connection) -> dict[str, str]:
    try:
        rows = con.execute("SELECT key, value FROM meta").fetchall()
        return dict(rows)
    except sqlite3.Error:
        return {}


def _read_update_cache() -> dict[str, Any] | None:
    try:
        data = json.loads(UPDATE_CACHE.read_text(encoding="utf-8"))
        if time.time() - float(data.get("checked_at", 0)) < UPDATE_CACHE_TTL:
            return data
    except (OSError, ValueError):
        pass
    return None


def _check_law7_latest() -> dict[str, Any]:
    """Смотрит, есть ли у law7 бэкап новее нашего снапшота (кэш на сутки)."""
    cached = _read_update_cache()
    if cached:
        return cached
    result: dict[str, Any] = {"checked_at": time.time(), "latest_backup": None, "error": None}
    try:
        with urllib.request.urlopen(LAW7_BACKUP_DOC, timeout=10) as resp:
            text = resp.read().decode("utf-8", errors="replace")
        backups = re.findall(r"law7_backup_(\d{8})_\d+\.tar\.gz", text)
        if backups:
            result["latest_backup"] = max(backups)  # YYYYMMDD
    except Exception as exc:  # noqa: BLE001 — сеть не должна ломать инструмент
        result["error"] = str(exc)
    try:
        UPDATE_CACHE.parent.mkdir(parents=True, exist_ok=True)
        UPDATE_CACHE.write_text(json.dumps(result), encoding="utf-8")
    except OSError:
        pass
    return result


mcp = FastMCP(
    name="laws",
    instructions=(
        "laws — локальная база российского права (официальные тексты кодексов, письма "
        "Минфина/ФНС, документы ВС, публикации pravo.gov.ru). Используй для ТОЧНЫХ "
        "текстов норм и разъяснений со ссылками. Данные — снапшот (не 'живые'): "
        "всегда сообщай дату снапшота из laws_status и советуй сверять актуальность "
        "по официальному источнику."
    ),
)


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def laws_status(
    check_updates: Annotated[
        bool, Field(description="Проверить у law7 свежий бэкап (сеть, кэш на сутки).")
    ] = True,
) -> dict[str, Any]:
    """Статус базы законов: снапшот, размеры, наличие публикаций, обновления."""
    con = _open_core()
    try:
        meta = _meta(con)
        codes = [
            {"code_id": row[0], "name": CODE_NAMES.get(row[0], row[0]), "articles": row[1]}
            for row in con.execute(
                "SELECT code_id, count(*) FROM articles GROUP BY code_id ORDER BY 2 DESC"
            )
        ]
    finally:
        con.close()
    status: dict[str, Any] = {
        "snapshot_date": meta.get("snapshot_date"),
        "built_at": meta.get("built_at"),
        "counts": {
            "articles": meta.get("articles"),
            "interpretations": meta.get("interpretations"),
            "decisions": meta.get("decisions"),
        },
        "codes": codes,
        "publications_installed": PUBLICATIONS_DB.exists(),
        "ruslaw_installed": RUSLAW_DB.exists(),
        "source": meta.get("source"),
        "note": (
            "Данные не живые: это снапшот официальных публикаций. "
            "Для актуальности на сегодня сверяйте с первоисточником."
        ),
    }
    if RUSLAW_DB.exists():
        try:
            con2 = _open_ruslaw()
            row = con2.execute(
                "SELECT count(*), sum(repealed), min(doc_date), max(doc_date) FROM acts"
            ).fetchone()
            m2 = _meta(con2)
            con2.close()
            status["ruslaw"] = {
                "acts": row[0],
                "repealed": row[1] or 0,
                "date_min": row[2],
                "date_max": row[3],
                "built_at": m2.get("built_at"),
                "fts": m2.get("fts"),
                "license": m2.get("license"),
            }
        except Exception as exc:  # noqa: BLE001
            status["ruslaw_error"] = str(exc)
    if check_updates:
        latest = _check_law7_latest()
        status["law7_latest_backup"] = latest.get("latest_backup")
        local_build = (meta.get("built_at") or "").replace("-", "")
        status["update_check_note"] = (
            "Если law7_latest_backup новее снапшота — пересоберите базу: "
            "bash laws/build/build_from_backup.sh, затем обновите артефакт релиза."
        )
        if latest.get("latest_backup") and local_build:
            status["update_available"] = latest["latest_backup"] > local_build
        if latest.get("error"):
            status["update_check_error"] = latest["error"]
    return status


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def list_codes() -> list[dict[str, Any]]:
    """Список кодексов в базе (code_id, название, число статей)."""
    con = _open_core()
    try:
        return [
            {"code_id": row[0], "name": CODE_NAMES.get(row[0], row[0]), "articles": row[1]}
            for row in con.execute(
                "SELECT code_id, count(*) FROM articles GROUP BY code_id ORDER BY code_id"
            )
        ]
    finally:
        con.close()


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def search_code_articles(
    query: Annotated[str, Field(description="Поисковый запрос, например 'уменьшение неустойки'.")],
    code_id: Annotated[
        str | None, Field(description="Ограничить кодексом: GK_RF_2, UK_RF, NK_RF_2…")
    ] = None,
    limit: Annotated[int, Field(description="Максимум результатов.", ge=1, le=25)] = 10,
) -> list[dict[str, Any]]:
    """Поиск по текстам статей кодексов (полнотекстовый, FTS5)."""
    con = _open_core()
    try:
        sql = (
            "SELECT a.code_id, a.article_number, a.title, "
            "snippet(articles_fts, 1, '«', '»', ' … ', 12) AS snip "
            "FROM articles_fts JOIN articles a ON a.rowid = articles_fts.rowid "
            "WHERE articles_fts MATCH ?"
        )
        params: list[Any] = [_fts_query(query)]
        if code_id:
            sql += " AND a.code_id = ?"
            params.append(code_id)
        sql += " LIMIT ?"
        params.append(limit)
        rows = con.execute(sql, params).fetchall()
        return [
            {
                "code_id": r[0],
                "code_name": CODE_NAMES.get(r[0], r[0]),
                "article_number": r[1],
                "title": r[2],
                "snippet": r[3],
            }
            for r in rows
        ]
    finally:
        con.close()


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def get_code_article(
    code_id: Annotated[str, Field(description="Кодекс: GK_RF_2, UK_RF, NK_RF… (см. list_codes)")],
    article_number: Annotated[str, Field(description="Номер статьи: '333', '158', '20.3' и т.п.")],
) -> dict[str, Any]:
    """Полный текст статьи кодекса из снапшота (с точной ссылкой на источник)."""
    con = _open_core()
    try:
        row = con.execute(
            "SELECT article_number, title, text, version_date, source FROM articles "
            "WHERE code_id = ? AND (article_number = ? OR article_number_consultant = ? "
            "OR article_number_consultant LIKE ?) ORDER BY length(article_number) LIMIT 1",
            (code_id, article_number, article_number, f"{article_number}(%"),
        ).fetchone()
        if row is None:
            raise ToolError(
                f"Статья {article_number} не найдена в {code_id} (снапшот). "
                "Проверь номер/кодекс через list_codes/search_code_articles."
            )
        meta = _meta(con)
        return {
            "code_id": code_id,
            "code_name": CODE_NAMES.get(code_id, code_id),
            "article_number": row[0],
            "title": row[1],
            "text": row[2],
            "source_act_date": row[3],
            "source": row[4],
            "snapshot_date": meta.get("snapshot_date"),
            "note": "Текст из снапшота; для актуальной редакции сверьте с официальным источником.",
        }
    finally:
        con.close()


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def search_interpretations(
    query: Annotated[str, Field(description="Запрос, например 'налоговый вычет обучение'.")],
    agency: Annotated[str | None, Field(description="Орган: 'Минфин', 'ФНС', 'Роструд'…")] = None,
    date_from: Annotated[str | None, Field(description="Не ранее (ГГГГ-ММ-ДД).")] = None,
    date_to: Annotated[str | None, Field(description="Не позднее (ГГГГ-ММ-ДД).")] = None,
    limit: Annotated[int, Field(description="Максимум результатов.", ge=1, le=25)] = 10,
) -> list[dict[str, Any]]:
    """Поиск писем и разъяснений ведомств (Минфин, ФНС) с фильтрами по дате/органу."""
    con = _open_core()
    try:
        sql = (
            "SELECT i.id, i.doc_date, i.agency, i.title, i.doc_number, i.source_url, "
            "snippet(interpretations_fts, 1, '«', '»', ' … ', 14) AS snip "
            "FROM interpretations_fts JOIN interpretations i ON i.rowid = interpretations_fts.rowid "
            "WHERE interpretations_fts MATCH ?"
        )
        params: list[Any] = [_fts_query(query)]
        if agency:
            sql += " AND i.agency LIKE ?"
            params.append(f"%{agency}%")
        if date_from:
            sql += " AND i.doc_date >= ?"
            params.append(date_from)
        if date_to:
            sql += " AND i.doc_date <= ?"
            params.append(date_to)
        sql += " ORDER BY i.doc_date DESC LIMIT ?"
        params.append(limit)
        return [
            {
                "id": r[0],
                "date": r[1],
                "agency": r[2],
                "title": r[3],
                "doc_number": r[4],
                "source_url": r[5],
                "snippet": r[6],
            }
            for r in con.execute(sql, params).fetchall()
        ]
    finally:
        con.close()


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def get_interpretation(
    interpretation_id: Annotated[str, Field(description="id из search_interpretations.")],
    max_chars: Annotated[
        int, Field(description="Ограничение длины текста.", ge=1000, le=100000)
    ] = 60000,
) -> dict[str, Any]:
    """Полный текст письма/разъяснения по id."""
    con = _open_core()
    try:
        row = con.execute(
            "SELECT doc_date, agency, title, doc_number, content, source_url, truncated, validity "
            "FROM interpretations WHERE id = ?",
            (interpretation_id,),
        ).fetchone()
        if row is None:
            raise ToolError("Письмо не найдено по id — проверь search_interpretations.")
        content = row[4] or ""
        return {
            "date": row[0],
            "agency": row[1],
            "title": row[2],
            "doc_number": row[3],
            "content": content[:max_chars],
            "truncated": bool(row[6]) or len(content) > max_chars,
            "source_url": row[5],
            "validity": row[7],
        }
    finally:
        con.close()


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def search_court_decisions(
    query: Annotated[str, Field(description="Запрос по документам ВС РФ.")],
    limit: Annotated[int, Field(description="Максимум результатов.", ge=1, le=25)] = 10,
) -> list[dict[str, Any]]:
    """Поиск по документам Верховного Суда (постановления Пленума и др., краткие описания)."""
    con = _open_core()
    try:
        rows = con.execute(
            "SELECT d.id, d.court_type, d.decision_type, d.case_number, d.decision_date, "
            "d.title, d.source_url, snippet(decisions_fts, 1, '«', '»', ' … ', 14) AS snip "
            "FROM decisions_fts JOIN decisions d ON d.rowid = decisions_fts.rowid "
            "WHERE decisions_fts MATCH ? LIMIT ?",
            (_fts_query(query), limit),
        ).fetchall()
        return [
            {
                "id": r[0],
                "court_type": r[1],
                "decision_type": r[2],
                "case_number": r[3],
                "date": r[4],
                "title": r[5],
                "source_url": r[6],
                "snippet": r[7],
            }
            for r in rows
        ]
    finally:
        con.close()


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def get_court_decision(
    decision_id: Annotated[str, Field(description="id из search_court_decisions.")],
) -> dict[str, Any]:
    """Документ ВС по id (краткое описание; в law7 полных текстов решений нет)."""
    con = _open_core()
    try:
        row = con.execute(
            "SELECT court_type, decision_type, case_number, decision_date, title, summary, "
            "source_url, binding FROM decisions WHERE id = ?",
            (decision_id,),
        ).fetchone()
        if row is None:
            raise ToolError("Документ не найден по id — проверь search_court_decisions.")
        return {
            "court_type": row[0],
            "decision_type": row[1],
            "case_number": row[2],
            "date": row[3],
            "title": row[4],
            "summary": row[5],
            "source_url": row[6],
            "binding": row[7],
        }
    finally:
        con.close()


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def search_publications(
    query: Annotated[str, Field(description="Поиск по названию опубликованного акта.")],
    block: Annotated[
        str | None, Field(description="Префикс блока публикации (0001 — федеральные акты).")
    ] = None,
    date_from: Annotated[
        str | None, Field(description="Дата публикации, не ранее (ГГГГ-ММ-ДД).")
    ] = None,
    date_to: Annotated[
        str | None, Field(description="Дата публикации, не позднее (ГГГГ-ММ-ДД).")
    ] = None,
    limit: Annotated[int, Field(description="Максимум результатов.", ge=1, le=25)] = 10,
) -> list[dict[str, Any]]:
    """Поиск по базе официальных публикаций pravo.gov.ru (2019–2026, 1,1 млн актов).

    Нужен для проверки официального опубликования и реквизитов. Опциональный компонент.
    """
    con = _open_publications()
    try:
        sql = (
            "SELECT p.eo_number, p.publish_date, p.doc_number, p.name, p.complex_name, p.annotation "
            "FROM publications_fts JOIN publications p ON p.rowid = publications_fts.rowid "
            "WHERE publications_fts MATCH ?"
        )
        params: list[Any] = [_fts_query(query)]
        if block:
            sql += " AND p.block = ?"
            params.append(block)
        if date_from:
            sql += " AND p.publish_date >= ?"
            params.append(date_from)
        if date_to:
            sql += " AND p.publish_date <= ?"
            params.append(date_to)
        sql += " ORDER BY p.publish_date DESC LIMIT ?"
        params.append(limit)
        rows = con.execute(sql, params).fetchall()
        return [
            {
                "eo_number": r[0],
                "publish_date": r[1],
                "doc_number": r[2],
                "name": r[3],
                "official_name": r[4],
                "annotation": r[5],
                "url": f"https://publication.pravo.gov.ru/document/{r[0]}",
            }
            for r in rows
        ]
    finally:
        con.close()


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def get_publication(
    eo_number: Annotated[str, Field(description="eo_number из search_publications.")],
) -> dict[str, Any]:
    """Публикация по eo_number: реквизиты + ссылка на официальный источник."""
    con = _open_publications()
    try:
        row = con.execute(
            "SELECT eo_number, block, publish_date, doc_number, name, complex_name, annotation "
            "FROM publications WHERE eo_number = ?",
            (eo_number,),
        ).fetchone()
        if row is None:
            raise ToolError("Публикация не найдена — проверь eo_number.")
        return {
            "eo_number": row[0],
            "block": row[1],
            "publish_date": row[2],
            "doc_number": row[3],
            "name": row[4],
            "official_name": row[5],
            "annotation": row[6],
            "url": f"https://publication.pravo.gov.ru/document/{row[0]}",
        }
    finally:
        con.close()


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def search_law_acts(
    query: Annotated[
        str | None,
        Field(description="Поиск по названию/тексту акта (FTS), напр. 'о персональных данных'."),
    ] = None,
    doc_number: Annotated[
        str | None,
        Field(description="Точный номер акта, напр. '152-ФЗ' (может повторяться в разные годы)."),
    ] = None,
    repealed: Annotated[
        bool | None,
        Field(description="True — только утратившие силу; False — только действующие; None — все."),
    ] = None,
    doc_type: Annotated[
        str | None, Field(description="Тип акта: 'Федеральный закон', 'Указ', 'Постановление'…")
    ] = None,
    date_from: Annotated[str | None, Field(description="Дата акта, не ранее (ГГГГ-ММ-ДД).")] = None,
    date_to: Annotated[str | None, Field(description="Дата акта, не позднее (ГГГГ-ММ-ДД).")] = None,
    limit: Annotated[int, Field(description="Максимум результатов.", ge=1, le=25)] = 10,
) -> list[dict[str, Any]]:
    """Поиск по полному корпусу актов РФ (RusLawOD: 310 тыс. документов 1991–2026).

    Для конкретного закона удобнее doc_number + date-фильтры; для темы — query.
    Возвращает метаданные и id для get_law_act (полный текст).
    """
    if not query and not doc_number:
        raise ToolError("search_law_acts: укажи query (по теме) или doc_number (точный номер).")
    con = _open_ruslaw()
    try:
        sql = (
            "SELECT a.id, a.doc_number, a.doc_date, a.doc_type, a.heading, a.status, a.repealed "
            "FROM acts a"
        )
        params: list[Any] = []
        where: list[str] = []
        if query:
            sql += " JOIN acts_fts f ON f.rowid = a.rowid"
            where.append("acts_fts MATCH ?")
            params.append(_fts_query(query))
        if doc_number:
            where.append("a.doc_number = ?")
            params.append(doc_number)
        if repealed is not None:
            where.append("a.repealed = ?")
            params.append(1 if repealed else 0)
        if doc_type:
            where.append("a.doc_type LIKE ?")
            params.append(f"%{doc_type}%")
        if date_from:
            where.append("a.doc_date >= ?")
            params.append(date_from)
        if date_to:
            where.append("a.doc_date <= ?")
            params.append(date_to)
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY a.doc_date DESC LIMIT ?"
        params.append(limit)
        rows = con.execute(sql, params).fetchall()
        return [
            {
                "id": r[0],
                "doc_number": r[1],
                "doc_date": r[2],
                "doc_type": r[3],
                "heading": r[4],
                "status": r[5],
                "repealed": bool(r[6]),
            }
            for r in rows
        ]
    finally:
        con.close()


@mcp.tool(annotations={"readOnlyHint": True, "idempotentHint": True})
def get_law_act(
    act_id: Annotated[str, Field(description="id из search_law_acts (pravogovruNd).")],
    max_chars: Annotated[
        int, Field(description="Ограничение длины текста.", ge=1000, le=100000)
    ] = 60000,
) -> dict[str, Any]:
    """Полный текст акта из корпуса RusLawOD + метаданные (статус, орган, дата)."""
    con = _open_ruslaw()
    try:
        row = con.execute(
            "SELECT id, doc_number, doc_date, heading, doc_type, authority, signed, status, "
            "repealed, widely_used, classifier, keywords, scraped_at, text FROM acts WHERE id = ?",
            (act_id,),
        ).fetchone()
        if row is None:
            raise ToolError("Акт не найден по id — проверь search_law_acts.")
        text = row[13] or ""
        meta = _meta(con)
        return {
            "id": row[0],
            "doc_number": row[1],
            "doc_date": row[2],
            "heading": row[3],
            "doc_type": row[4],
            "authority": row[5],
            "signed": row[6],
            "status": row[7],
            "repealed": bool(row[8]),
            "widely_used": bool(row[9]),
            "classifier": row[10],
            "keywords": row[11],
            "scraped_at": row[12],
            "text": text[:max_chars],
            "truncated": len(text) > max_chars,
            "corpus": "RusLawOD (CC BY-NC 4.0, pet-проект)",
            "corpus_built_at": meta.get("built_at"),
        }
    finally:
        con.close()


def main() -> None:
    logger.info("Starting laws-mcp — core=%s publications=%s", CORE_DB, PUBLICATIONS_DB.exists())
    mcp.run()


if __name__ == "__main__":
    main()

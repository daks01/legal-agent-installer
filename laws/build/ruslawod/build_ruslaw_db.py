#!/usr/bin/env python3
"""RusLawOD (single-zip) → SQLite для MCP `laws`.

Читает исправленный single-zip (см. fix_split_zip.py), парсит XML-акты и собирает
`ruslaw.db`: таблица acts + FTS5 (название/ключевые слова/текст, опционально),
meta-сведения о корпусе.

Использование:
  python3 build_ruslaw_db.py --src corpus_xml_lite_merged_single.zip --out ruslaw.db
  python3 build_ruslaw_db.py ... --fts head   # индексировать первые 4000 символов текста
"""

from __future__ import annotations

import argparse
import os
import sqlite3
import sys
import time
import xml.etree.ElementTree as ET
import zipfile
from datetime import date, datetime

PROGRESS_EVERY = 10000


def _val(root: ET.Element, path: str) -> str:
    el = root.find(path)
    if el is None:
        return ""
    return (el.get("val") or "").strip()


def _text(root: ET.Element) -> str:
    el = root.find("body/textIPS")
    if el is None:
        return ""
    text = "".join(el.itertext())
    return text.replace("\r\n", "\n").replace("\r", "\n").strip()


def _iso_date(ddmmyyyy: str) -> str:
    try:
        return datetime.strptime(ddmmyyyy, "%d.%m.%Y").date().isoformat()
    except (ValueError, TypeError):
        return ""


def parse_act(name: str, data: bytes) -> dict | None:
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        return None
    ident = "meta/identification"
    text = _text(root)
    status = _val(root, f"{ident}/statusIPS")
    # нормализация вариатов («Действует c изменениями» с латинской c и т.п.)
    status = status.replace(" c ", " с ")
    if status.lower().startswith("действует с измен"):
        status = "Действует с изменениями"
    elif status.lower().startswith("действует без измен"):
        status = "Действует без изменений"
    heading = _val(root, f"{ident}/headingIPS")
    if not text and not heading:
        return None
    classifiers = [el.get("val") or "" for el in root.findall("meta/reference/classifierByIPS")]
    keywords = [el.get("val") or "" for el in root.findall("meta/keywords/keywordsByIPS")]
    doc_id = _val(root, f"{ident}/pravogovruNd") or name.rsplit("/", 1)[-1].removesuffix(".xml")
    return {
        "id": doc_id,
        "doc_number": _val(root, f"{ident}/docNumberIPS"),
        "doc_date": _iso_date(_val(root, f"{ident}/docdateIPS")),
        "heading": heading,
        "doc_type": _val(root, f"{ident}/doc_typeIPS"),
        "authority": _val(root, f"{ident}/issuedByIPS"),
        "signed": _val(root, f"{ident}/signedIPS"),
        "status": status,
        "repealed": 1 if "утратил силу" in status.lower() else 0,
        "widely_used": 1 if _val(root, f"{ident}/is_widely_used") == "1" else 0,
        "classifier": "; ".join(c for c in classifiers if c),
        "keywords": ", ".join(k for k in keywords if k),
        "scraped_at": _val(root, f"{ident}/actual_datetime_humanIPS"),
        "text": text,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--src", required=True, help="single-zip (после fix_split_zip.py)")
    ap.add_argument("--out", required=True, help="путь к ruslaw.db")
    ap.add_argument(
        "--fts",
        choices=("full", "head", "off"),
        default="head",
        help="полнотекстовый индекс: всё / первые 4000 символов / без текста",
    )
    ap.add_argument("--limit", type=int, default=0, help="обработать только N актов (отладка)")
    args = ap.parse_args()

    if os.path.exists(args.out):
        print(f"= удаляю прежний {args.out}")
        os.remove(args.out)

    con = sqlite3.connect(args.out)
    con.executescript("""
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
CREATE TABLE acts(
  id TEXT PRIMARY KEY, doc_number TEXT, doc_date TEXT, heading TEXT,
  doc_type TEXT, authority TEXT, signed TEXT, status TEXT, repealed INTEGER,
  widely_used INTEGER, classifier TEXT, keywords TEXT, scraped_at TEXT, text TEXT
);
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
""")

    started = time.time()
    total = parsed = skipped = 0
    batch: list[tuple] = []
    insert_sql = (
        "INSERT OR REPLACE INTO acts(id, doc_number, doc_date, heading, doc_type, "
        "authority, signed, status, repealed, widely_used, classifier, keywords, "
        "scraped_at, text) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
    )

    with zipfile.ZipFile(args.src) as z:
        entries = [i for i in z.infolist() if not i.is_dir() and i.filename.endswith(".xml")]
        print(f"актов в архиве: {len(entries)}", flush=True)
        for info in entries:
            if args.limit and total >= args.limit:
                break
            total += 1
            act = parse_act(info.filename, z.read(info))
            if act is None:
                skipped += 1
                continue
            batch.append(
                tuple(
                    act[k]
                    for k in (
                        "id",
                        "doc_number",
                        "doc_date",
                        "heading",
                        "doc_type",
                        "authority",
                        "signed",
                        "status",
                        "repealed",
                        "widely_used",
                        "classifier",
                        "keywords",
                        "scraped_at",
                        "text",
                    )
                )
            )
            parsed += 1
            if len(batch) >= 500:
                con.executemany(insert_sql, batch)
                con.commit()
                batch.clear()
            if total % PROGRESS_EVERY == 0:
                rate = total / (time.time() - started)
                print(f"  {total} обработано ({rate:.0f}/с), пропущено {skipped}", flush=True)
    if batch:
        con.executemany(insert_sql, batch)
    con.commit()

    print(f"▸ распарсено {parsed}, пропущено {skipped} за {time.time() - started:.0f}с", flush=True)

    if args.fts != "off":
        print("▸ строю FTS5…", flush=True)
        t0 = time.time()
        if args.fts == "head":
            con.executescript("""
CREATE VIRTUAL TABLE acts_fts USING fts5(
  heading, keywords, text_head, content='', tokenize='unicode61');
INSERT INTO acts_fts(rowid, heading, keywords, text_head)
  SELECT rowid, heading, keywords, substr(text, 1, 4000) FROM acts;
""")
        else:
            con.executescript("""
CREATE VIRTUAL TABLE acts_fts USING fts5(
  heading, keywords, text, content='acts', content_rowid='rowid', tokenize='unicode61');
INSERT INTO acts_fts(rowid, heading, keywords, text)
  SELECT rowid, heading, keywords, text FROM acts;
""")
        print(f"  FTS готов за {time.time() - t0:.0f}с", flush=True)

    print("▸ индексы и meta…", flush=True)
    con.executescript("""
CREATE INDEX idx_acts_number ON acts(doc_number);
CREATE INDEX idx_acts_date ON acts(doc_date);
CREATE INDEX idx_acts_status ON acts(repealed);
CREATE INDEX idx_acts_type ON acts(doc_type);
""")
    counts = con.execute(
        "SELECT count(*), sum(repealed), max(doc_date), min(doc_date) FROM acts"
    ).fetchone()
    meta = {
        "source": "github.com/irlcode/RusLawOD (corpus_xml_lite)",
        "license": "CC BY-NC 4.0 (некоммерческое; pet-проект)",
        "built_at": date.today().isoformat(),
        "acts": str(counts[0]),
        "acts_repealed": str(counts[1] or 0),
        "date_min": counts[3] or "",
        "date_max": counts[2] or "",
        "fts": args.fts,
    }
    con.executemany("INSERT OR REPLACE INTO meta VALUES (?,?)", meta.items())
    con.commit()
    con.execute("VACUUM")
    con.close()

    size = __import__("os").path.getsize(args.out)
    print(
        f"✓ Готово: {args.out} — {size / 1024 / 1024:.0f} МБ, актов {counts[0]}, "
        f"утратило силу {counts[1] or 0}, даты {counts[3]}…{counts[2]}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

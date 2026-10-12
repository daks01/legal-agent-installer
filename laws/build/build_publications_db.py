#!/usr/bin/env python3
"""Собирает laws-publications.db (опциональная база публикаций pravo.gov.ru) из CSV.

Использование: python3 build_publications_db.py <csv_dir> <out.db>
"""

import csv
import sqlite3
import sys
import time
from pathlib import Path

SRC = Path(sys.argv[1])
DB = Path(sys.argv[2])

if DB.exists():
    DB.unlink()

con = sqlite3.connect(DB)
con.executescript("""
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
CREATE TABLE publications(
  eo_number TEXT PRIMARY KEY, block TEXT, name TEXT, complex_name TEXT,
  doc_number TEXT, doc_date TEXT, publish_date TEXT, annotation TEXT
);
""")


def clip(value: str, limit: int) -> str:
    return (value or "").strip()[:limit]


t0 = time.time()
with open(SRC / "publications.csv", encoding="utf-8", newline="") as f:
    reader = csv.reader(f)
    next(reader)
    batch = []
    n = 0
    for row in reader:
        eo, block, name, complex_name, doc_number, doc_date, pub_date, _pdf, _html, annotation = row
        batch.append(
            (
                eo,
                block,
                clip(name, 150),
                clip(complex_name, 170),
                clip(doc_number, 60),
                doc_date,
                pub_date,
                clip(annotation, 500),
            )
        )
        if len(batch) >= 5000:
            con.executemany("INSERT OR IGNORE INTO publications VALUES (?,?,?,?,?,?,?,?)", batch)
            n += len(batch)
            batch = []
    if batch:
        con.executemany("INSERT OR IGNORE INTO publications VALUES (?,?,?,?,?,?,?,?)", batch)
        n += len(batch)
con.commit()
print(f"publications: {n} строк за {time.time() - t0:.1f}с")

t0 = time.time()
con.executescript("""
CREATE INDEX idx_pub_date ON publications(publish_date);
CREATE INDEX idx_pub_docnum ON publications(doc_number);
CREATE INDEX idx_pub_block ON publications(block);
CREATE VIRTUAL TABLE publications_fts USING fts5(
  name, content='publications', content_rowid='rowid', tokenize='unicode61');
INSERT INTO publications_fts(rowid, name) SELECT rowid, name FROM publications;
INSERT INTO publications_fts(publications_fts) VALUES('optimize');
VACUUM;
""")
con.commit()
print(f"индексы+FTS+vacuum: {time.time() - t0:.1f}с")

cur = con.cursor()
cur.execute("SELECT count(*) FROM publications")
print("всего:", cur.fetchone()[0])
cur.execute("""SELECT p.publish_date, p.doc_number, substr(p.name,1,70)
               FROM publications_fts JOIN publications p ON p.rowid = publications_fts.rowid
               WHERE publications_fts MATCH 'персональн* AND данных*' LIMIT 3""")
print("тест FTS:", cur.fetchall())
con.close()
print(f"Готово: {DB} — {DB.stat().st_size / 1024 / 1024:.1f} МБ")

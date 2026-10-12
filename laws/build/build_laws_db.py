#!/usr/bin/env python3
"""Собирает ядро laws.db (статьи кодексов + письма + документы ВС) из CSV-экспортов law7.

Использование:
  python3 build_laws_db.py <csv_dir> <out.db> [key=value ... для meta]
"""

import csv
import sqlite3
import sys
import time
from datetime import date
from pathlib import Path

SRC = Path(sys.argv[1])
DB = Path(sys.argv[2])
META = dict(arg.split("=", 1) for arg in sys.argv[3:] if "=" in arg)

if DB.exists():
    DB.unlink()

con = sqlite3.connect(DB)
con.executescript("""
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
CREATE TABLE articles(
  code_id TEXT NOT NULL, article_number TEXT NOT NULL, article_number_consultant TEXT,
  title TEXT, text TEXT, version_date TEXT, is_current INTEGER, is_repealed INTEGER, source TEXT
);
CREATE TABLE interpretations(
  id TEXT, agency TEXT, doc_number TEXT, doc_date TEXT, title TEXT, content TEXT,
  topic TEXT, validity TEXT, source_url TEXT, truncated INTEGER
);
CREATE TABLE decisions(
  id TEXT, court_type TEXT, court_level TEXT, decision_type TEXT, case_number TEXT,
  decision_date TEXT, title TEXT, summary TEXT, legal_issues TEXT, binding TEXT, source_url TEXT
);
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
CREATE INDEX idx_art ON articles(code_id, article_number);
CREATE INDEX idx_art_cons ON articles(article_number_consultant);
CREATE INDEX idx_interp_agency ON interpretations(agency, doc_date);
CREATE INDEX idx_interp_date ON interpretations(doc_date);
""")


def load(table: str, csv_name: str, cols: list[str]) -> int:
    t0 = time.time()
    n = 0
    with open(SRC / csv_name, encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        next(reader)
        sql = f"INSERT INTO {table}({','.join(cols)}) VALUES ({','.join('?' for _ in cols)})"
        batch = []
        for row in reader:
            batch.append(row[: len(cols)])
            if len(batch) >= 1000:
                con.executemany(sql, batch)
                n += len(batch)
                batch = []
        if batch:
            con.executemany(sql, batch)
            n += len(batch)
    con.commit()
    print(f"{table}: {n} строк за {time.time() - t0:.1f}с")
    return n


n_art = load(
    "articles",
    "articles.csv",
    [
        "code_id",
        "article_number",
        "article_number_consultant",
        "title",
        "text",
        "version_date",
        "is_current",
        "is_repealed",
        "source",
    ],
)
n_int = load(
    "interpretations",
    "interpretations.csv",
    [
        "id",
        "agency",
        "doc_number",
        "doc_date",
        "title",
        "content",
        "topic",
        "validity",
        "source_url",
        "truncated",
    ],
)
n_dec = load(
    "decisions",
    "decisions.csv",
    [
        "id",
        "court_type",
        "court_level",
        "decision_type",
        "case_number",
        "decision_date",
        "title",
        "summary",
        "legal_issues",
        "binding",
        "source_url",
    ],
)

t0 = time.time()
con.executescript("""
CREATE VIRTUAL TABLE articles_fts USING fts5(
  title, text, content='articles', content_rowid='rowid', tokenize='unicode61');
INSERT INTO articles_fts(rowid, title, text) SELECT rowid, title, text FROM articles;
CREATE VIRTUAL TABLE interpretations_fts USING fts5(
  title, content, content='interpretations', content_rowid='rowid', tokenize='unicode61');
INSERT INTO interpretations_fts(rowid, title, content) SELECT rowid, title, content FROM interpretations;
CREATE VIRTUAL TABLE decisions_fts USING fts5(
  title, summary, content='decisions', content_rowid='rowid', tokenize='unicode61');
INSERT INTO decisions_fts(rowid, title, summary) SELECT rowid, title, summary FROM decisions;
INSERT INTO articles_fts(articles_fts) VALUES('optimize');
INSERT INTO interpretations_fts(interpretations_fts) VALUES('optimize');
INSERT INTO decisions_fts(decisions_fts) VALUES('optimize');
""")
con.commit()
print(f"FTS-индексы: {time.time() - t0:.1f}с")

meta = {
    "articles": str(n_art),
    "interpretations": str(n_int),
    "decisions": str(n_dec),
    "built_at": date.today().isoformat(),
    "license": "официальные документы (ГК РФ ст. 1259); сборка law7 (AGPL-3.0)",
    "source": "github.com/mikhashev/law7",
}
meta.update(META)
con.executemany("INSERT OR REPLACE INTO meta VALUES (?,?)", meta.items())
con.executescript("VACUUM;")
con.close()
print(f"Готово: {DB} — {DB.stat().st_size / 1024 / 1024:.1f} МБ")

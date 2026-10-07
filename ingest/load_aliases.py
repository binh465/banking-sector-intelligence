"""Snapshot config/aliases.yaml into raw.raw_alias (one row per term).

Terms are normalised to Unicode NFC so a name typed in decomposed form still compares as typed.
Full reload in one transaction, with a row count check. Run again after any change to the yaml.

Run from the repository root:  python ingest/load_aliases.py
"""
import unicodedata

import yaml

from db import get_connection

ALIASES_PATH = "config/aliases.yaml"


def term(entry):
    """An entry is a plain string, or {text: ..., case_sensitive: true}."""
    if isinstance(entry, dict):
        return unicodedata.normalize("NFC", str(entry["text"]).strip()), bool(entry.get("case_sensitive", False))
    return unicodedata.normalize("NFC", str(entry).strip()), False


def condition(entry):
    """Exclusions only: {text: ..., when_title_contains: ...} is cut only from titles with that phrase."""
    if isinstance(entry, dict) and entry.get("when_title_contains"):
        return unicodedata.normalize("NFC", str(entry["when_title_contains"]).strip())
    return None


def flag(b):
    return "1" if b else "0"


def main():
    with open(ALIASES_PATH, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)

    rows = []
    for e in cfg.get("context_words", []):
        t, cs = term(e)
        rows.append(["context", None, None, None, t, flag(cs), None])
    for e in cfg.get("exclusions", []):
        t, cs = term(e)
        rows.append(["exclusion", None, None, None, t, flag(cs), condition(e)])
    for b in cfg["banks"]:
        ticker = b.get("ticker")
        bank_id = ticker or b.get("id")
        if not bank_id:
            raise SystemExit(f"{ALIASES_PATH}: a bank entry has neither ticker nor id: {b}")
        for kind in ("strong", "weak"):
            for e in b.get(kind, []) or []:
                t, cs = term(e)
                rows.append([kind, bank_id, ticker, flag(b.get("in_scope", False)), t, flag(cs), None])

    cols = ["kind", "bank_id", "ticker", "in_scope", "term", "case_sensitive", "when_title_contains"]
    col_list = ", ".join(f"[{c}]" for c in cols + ["source_file"])
    placeholders = ", ".join("?" * (len(cols) + 1))
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute("TRUNCATE TABLE raw.raw_alias;")
        cur.executemany(f"INSERT INTO raw.raw_alias ({col_list}) VALUES ({placeholders});",
                        [r + [ALIASES_PATH] for r in rows])
        n = cur.execute("SELECT COUNT(*) FROM raw.raw_alias;").fetchone()[0]
        if n != len(rows):
            raise RuntimeError(f"raw.raw_alias: {n} rows in table, {len(rows)} from yaml")
        conn.commit()
        print(f"raw.raw_alias: {n} rows")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    main()

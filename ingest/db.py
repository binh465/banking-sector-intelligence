"""SQL Server connection helper for the ingestion scripts.

Reads config/db.yaml (git-ignored; template in config/db.example.yaml).
Values such as "yes" must be quoted in the YAML: PyYAML reads a bare yes as
the boolean True, which would end up as 'Trusted_Connection=True' in the
connection string.

Run from the repository root to test the connection:  python ingest/db.py
"""
from pathlib import Path

import pyodbc
import yaml

CONFIG_PATH = Path("config/db.yaml")


def load_db_config(path: Path = CONFIG_PATH) -> dict:
    if not path.exists():
        raise SystemExit(f"{path} not found - copy config/db.example.yaml to {path} and edit it.")
    with open(path, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    for key in ("trusted_connection", "trust_server_certificate"):
        if not isinstance(cfg[key], str):
            raise SystemExit(f"{path}: '{key}' must be a quoted string such as \"yes\", got {cfg[key]!r}.")
    return cfg


def get_connection() -> pyodbc.Connection:
    cfg = load_db_config()
    conn_str = (
        f"DRIVER={{{cfg['driver']}}};"
        f"SERVER={cfg['server']};"
        f"DATABASE={cfg['database']};"
        f"Trusted_Connection={cfg['trusted_connection']};"
        f"TrustServerCertificate={cfg['trust_server_certificate']};"
    )
    return pyodbc.connect(conn_str)


if __name__ == "__main__":
    with get_connection() as conn:
        row = conn.cursor().execute(
            "SELECT DB_NAME(), SUSER_SNAME(), "
            "CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS nvarchar(128))"
        ).fetchone()
        print(f"database={row[0]}  login={row[1]}  collation={row[2]}")

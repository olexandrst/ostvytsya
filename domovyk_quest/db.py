"""SQLite — єдине постійне сховище веб-панелі.

Усе, що панель раніше тримала в пам'яті чи в окремих файлах (статуси
терміналів, персонажі з телефонів, персонажі веб-редактора, обліковий запис
адміністратора, ключ підпису сесій), живе в одному файлі
`data/ostvytsya.db` (шлях можна змінити через OSTVYTSYA_DB_PATH). Жодних
зовнішніх залежностей — sqlite3 є в стандартній бібліотеці Python.

Модель роботи навмисно найпростіша: з'єднання на кожну операцію (для
панелі з одним адміністратором і десятком терміналів це копійки), WAL для
безпечних паралельних читань, схема створюється ідемпотентно при першому
зверненні. Міграцій немає — таблиці лише CREATE IF NOT EXISTS.

На хостингах з ефемерним диском (Render без Persistent Disk) файл зникне при
передеплої — там або прив'яжи диск і вкажи OSTVYTSYA_DB_PATH на нього, або
лишайся на PostgreSQL для персонажів (config.yaml → storage.backend).
"""

from __future__ import annotations

import os
import sqlite3
import threading
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator, Optional

_SCHEMA = """
CREATE TABLE IF NOT EXISTS characters (
    id         TEXT PRIMARY KEY,
    data       TEXT NOT NULL,      -- JSON того самого словника, що й у YAML
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS mobile_characters (
    id         TEXT PRIMARY KEY,
    doc        TEXT NOT NULL,      -- непрозорий JSON мобільного формату (або надгробок)
    updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS agents (
    agent_id    TEXT PRIMARY KEY,
    received_at REAL NOT NULL,
    data        TEXT NOT NULL      -- JSON очищеного статусу
);
CREATE TABLE IF NOT EXISTS users (
    username      TEXT PRIMARY KEY,
    password_hash TEXT NOT NULL,   -- pbkdf2_sha256$ітерації$сіль$хеш (web/auth.py)
    created_at    REAL NOT NULL,
    updated_at    REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
"""

_schema_lock = threading.Lock()
_schema_ready: set[str] = set()


def db_path() -> Path:
    raw = (os.environ.get("OSTVYTSYA_DB_PATH") or "").strip()
    if raw:
        return Path(raw).expanduser()
    return Path(__file__).resolve().parent.parent / "data" / "ostvytsya.db"


def _ensure_schema(conn: sqlite3.Connection, key: str) -> None:
    if key in _schema_ready:
        return
    with _schema_lock:
        if key in _schema_ready:
            return
        conn.executescript(_SCHEMA)
        conn.commit()
        _schema_ready.add(key)


@contextmanager
def connect() -> Iterator[sqlite3.Connection]:
    """З'єднання на одну операцію: commit при успіху, rollback при винятку."""
    path = db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        _ensure_schema(conn, str(path))
        yield conn
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    finally:
        conn.close()


# ── Дрібні налаштування «ключ → значення» ─────────────────────────────────────

def get_setting(key: str) -> Optional[str]:
    with connect() as conn:
        row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
    return None if row is None else str(row["value"])


def set_setting(key: str, value: str) -> None:
    with connect() as conn:
        conn.execute(
            "INSERT INTO settings (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )

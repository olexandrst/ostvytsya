"""Персонажі веб-редактора в SQLite — типовий бекенд збереження.

Той самий словник (YAML-еквівалент), що й у файловому бекенді
(characters.py) та в PostgreSQL (characters_pg.py), лише лежить у колонці
JSON таблиці `characters` спільної бази панелі (domovyk_quest/db.py). При
першому зверненні до порожньої таблиці персонажі з characters/*.yaml
імпортуються автоматично — щоб Домовичок, Водяник, Повітруля й Дерево не
«зникли» після переходу на базу.

Правила валідації (_check_payload, build_character) спільні з файловим
бекендом, тож повідомлення про помилки однакові незалежно від сховища.
"""

from __future__ import annotations

import json
import logging
import time
from typing import Any

from . import db
from .characters import (
    CharacterError,
    _check_payload,
    build_character,
    read_seed_files,
    summary,
    validate_id,
)

log = logging.getLogger("ostvytsya.characters_sqlite")


def _load(row: Any) -> dict[str, Any]:
    data = json.loads(row["data"])
    if not isinstance(data, dict):
        raise CharacterError("Запис персонажа пошкоджено.")
    return data


# ── читання ──────────────────────────────────────────────────────────────────

def read_raw(char_id: str) -> dict[str, Any]:
    cid = validate_id(char_id)
    with db.connect() as conn:
        row = conn.execute("SELECT data FROM characters WHERE id = ?", (cid,)).fetchone()
    if row is None:
        raise CharacterError(f"Персонажа «{char_id}» не знайдено.")
    return _load(row)


def list_characters() -> list[dict[str, Any]]:
    seed_from_files_if_empty()
    out: list[dict[str, Any]] = []
    with db.connect() as conn:
        rows = conn.execute("SELECT id, data FROM characters ORDER BY id").fetchall()
    for row in rows:
        try:
            raw = _load(row)
        except (CharacterError, ValueError, TypeError):
            continue  # пошкоджений запис не має ламати весь список
        out.append(summary(str(row["id"]), raw))
    return out


# ── запис ────────────────────────────────────────────────────────────────────

def save_raw(char_id: str, data: dict[str, Any], *, create: bool = False) -> str:
    cid = validate_id(char_id)
    _check_payload(data)
    with db.connect() as conn:
        exists = conn.execute("SELECT 1 FROM characters WHERE id = ?", (cid,)).fetchone()
        # Той самий порядок перевірок, що й у файловому бекенді.
        if create and exists:
            raise CharacterError(f"Персонаж «{cid}» уже існує.")
        if not create and not exists:
            raise CharacterError(f"Персонажа «{cid}» не знайдено.")
        payload = dict(data)
        payload["id"] = cid
        build_character(payload)  # переконатись, що з цього збирається персонаж
        conn.execute(
            "INSERT INTO characters (id, data, updated_at) VALUES (?, ?, ?) "
            "ON CONFLICT(id) DO UPDATE SET data = excluded.data, "
            "updated_at = excluded.updated_at",
            (cid, json.dumps(payload, ensure_ascii=False), time.time()),
        )
    return cid


def delete_character(char_id: str) -> None:
    cid = validate_id(char_id)
    with db.connect() as conn:
        cur = conn.execute("DELETE FROM characters WHERE id = ?", (cid,))
        if cur.rowcount == 0:
            raise CharacterError(f"Персонажа «{char_id}» не знайдено.")


def _unique_id(conn, base: str) -> str:
    """Підібрати вільний ідентифікатор: «makosh», «makosh-2», «makosh-3»…"""
    stem = validate_id(base)
    if conn.execute("SELECT 1 FROM characters WHERE id = ?", (stem,)).fetchone() is None:
        return stem
    for n in range(2, 1000):
        candidate = f"{stem}-{n}"[:64].strip("-")
        if conn.execute("SELECT 1 FROM characters WHERE id = ?", (candidate,)).fetchone() is None:
            return candidate
    raise CharacterError("Не вдалося підібрати вільний ідентифікатор.")


def clone_character(char_id: str) -> tuple[str, str]:
    """Створити копію персонажа з усім сценарієм. Повертає (новий_id, назва)."""
    raw = read_raw(char_id)
    with db.connect() as conn:
        new_id = _unique_id(conn, f"{validate_id(char_id)}-kopiia")
        name = (raw.get("display_name") or char_id).strip()
        payload = dict(raw)
        payload["display_name"] = f"{name} (копія)"
        payload["id"] = new_id
        conn.execute(
            "INSERT INTO characters (id, data, updated_at) VALUES (?, ?, ?)",
            (new_id, json.dumps(payload, ensure_ascii=False), time.time()),
        )
    return new_id, payload["display_name"]


# ── початкове наповнення ────────────────────────────────────────────────────

def seed_from_files_if_empty() -> None:
    """Порожня таблиця → імпортувати characters/*.yaml (одноразово)."""
    with db.connect() as conn:
        (count,) = conn.execute("SELECT count(*) FROM characters").fetchone()
        if count:
            return
        seeded = 0
        for char_id, payload in read_seed_files():
            conn.execute(
                "INSERT OR IGNORE INTO characters (id, data, updated_at) VALUES (?, ?, ?)",
                (char_id, json.dumps(payload, ensure_ascii=False), time.time()),
            )
            seeded += 1
    if seeded:
        log.info("SQLite: імпортовано %d персонаж(ів) із characters/*.yaml", seeded)

"""Персонажі в Render Managed PostgreSQL — опційний бекенд збереження.

Вмикається через config.yaml → storage.render: yes (див. config.render_storage_enabled).
Формат даних персонажа той самий словник (YAML-еквівалент), що й у файловому
бекенді (characters.py) — лише лежить у колонці JSONB замість окремого файлу.

Навіщо це взагалі потрібне: на хостингах на кшталт Render файлова система
веб-сервісу ЕФЕМЕРНА — усе, що записано на диск під час роботи (тобто нові чи
відредаговані у браузері персонажі), зникає при кожному передеплої й часто
при перезапуску інстансу. characters/*.yaml, що йдуть у репозиторії, лишаються
(вони частина коду), але створене чи змінене у веб-редакторі — ні. Render
Managed PostgreSQL — це окреме постійне сховище, не пов'язане з файловою
системою сервісу, тож персонажі виживають між деплоями.

Підключення береться зі змінної DATABASE_URL — Render підставляє її сама,
коли Managed PostgreSQL прив'язано до сервісу; для локального тесту можна
вписати рядок з'єднання в .env вручну.

psycopg — залежність ЛИШЕ цього модуля: якщо storage.render: no (типово),
пакет може бути навіть не встановлений — імпортується лише в момент виклику,
щоб не обтяжувати звичайний файловий деплой.
"""

from __future__ import annotations

import json
import logging
import os
import threading
from typing import Any

from .characters import CharacterError, _check_payload, build_character, validate_id

log = logging.getLogger("ostvytsya.characters_pg")

_TABLE = "ostvytsya_characters"
_schema_lock = threading.Lock()
_schema_ready = False


class StorageError(CharacterError):
    """Помилка бекенду PostgreSQL: з'єднання, конфігурація, відсутній пакет."""


def database_url() -> str:
    url = (os.environ.get("DATABASE_URL") or "").strip()
    if not url:
        raise StorageError(
            "config.yaml → storage.render: yes, але не задано DATABASE_URL. "
            "Прив'яжи Render Managed PostgreSQL до сервісу (Render підставить "
            "змінну сам) або впиши рядок з'єднання в .env для локального тесту."
        )
    # psycopg приймає лише "postgresql://"; деякі провайдери (Render, Heroku)
    # історично віддають "postgres://" — нормалізуємо.
    if url.startswith("postgres://"):
        url = "postgresql://" + url[len("postgres://"):]
    return url


def _connect():
    try:
        import psycopg
    except ImportError as exc:
        raise StorageError(
            "config.yaml → storage.render: yes потребує пакет psycopg. "
            "Встанови: pip install -r requirements-web.txt"
        ) from exc
    try:
        conn = psycopg.connect(database_url())
    except Exception as exc:  # noqa: BLE001 — будь-яка мережева/авторизаційна помилка
        raise StorageError(f"Не вдалося з'єднатися з PostgreSQL: {exc}") from exc
    _ensure_schema(conn)
    return conn


def _ensure_schema(conn) -> None:
    """Створити таблицю персонажів, якщо її ще немає (ідемпотентно)."""
    global _schema_ready
    if _schema_ready:
        return
    with _schema_lock:
        if _schema_ready:
            return
        with conn.cursor() as cur:
            cur.execute(f"""
                CREATE TABLE IF NOT EXISTS {_TABLE} (
                    id TEXT PRIMARY KEY,
                    data JSONB NOT NULL,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
                )
            """)
        conn.commit()
        _schema_ready = True


def _row_to_dict(value: Any) -> dict[str, Any]:
    # psycopg3 сам адаптує jsonb → dict; про всяк випадок підстраховуємось,
    # якщо драйвер повернув сирий текст.
    return value if isinstance(value, dict) else json.loads(value)


# ── читання ──────────────────────────────────────────────────────────────────

def read_raw(char_id: str) -> dict[str, Any]:
    cid = validate_id(char_id)
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(f"SELECT data FROM {_TABLE} WHERE id = %s", (cid,))
        row = cur.fetchone()
    if row is None:
        raise CharacterError(f"Персонажа «{char_id}» не знайдено.")
    return _row_to_dict(row[0])


def list_characters() -> list[dict[str, Any]]:
    seed_from_files_if_empty()
    out: list[dict[str, Any]] = []
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(f"SELECT id, data FROM {_TABLE} ORDER BY id")
        rows = cur.fetchall()
    for char_id, data in rows:
        try:
            raw = _row_to_dict(data)
        except (TypeError, ValueError):
            continue  # пошкоджений запис не має ламати весь список
        provider = (raw.get("provider") or "openai").strip()
        out.append({
            "id": char_id,
            "display_name": raw.get("display_name") or char_id,
            "provider": provider,
            "provider_label": "Google Gemini" if provider == "google" else "OpenAI",
            "voice": raw.get("voice") or "",
            "openai_voice": raw.get("openai_voice") or "marin",
            "web_voice": (raw.get("voice") or "Charon") if provider == "google"
                         else (raw.get("openai_voice") or "marin"),
            "wake_words": list(raw.get("wake_words") or []),
            "win_word": raw.get("win_word") or "",
            "questions": len(raw.get("questions") or []),
            "custom_prompt": bool((raw.get("system_prompt") or "").strip()),
        })
    return out


# ── запис ────────────────────────────────────────────────────────────────────
# Валідація (_check_payload) переюзана з characters.py — та сама, що й для
# файлового бекенду, щоб правила ніколи не розходилися між двома сховищами.

def save_raw(char_id: str, data: dict[str, Any], *, create: bool = False) -> str:
    cid = validate_id(char_id)
    _check_payload(data)

    with _connect() as conn, conn.cursor() as cur:
        cur.execute(f"SELECT 1 FROM {_TABLE} WHERE id = %s", (cid,))
        exists = cur.fetchone() is not None
        # Той самий порядок перевірок, що й у файловому бекенді: спершу
        # create/exists, і лише потім структурна валідація — щоб повідомлення
        # про помилку були однаковими незалежно від бекенду.
        if create and exists:
            raise CharacterError(f"Персонаж «{cid}» уже існує.")
        if not create and not exists:
            raise CharacterError(f"Персонажа «{cid}» не знайдено.")

        payload = dict(data)
        payload["id"] = cid
        # Перевіряємо, що з цього справді збирається персонаж, ще ДО запису.
        build_character(payload)

        cur.execute(f"""
            INSERT INTO {_TABLE} (id, data, updated_at) VALUES (%s, %s, now())
            ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data, updated_at = now()
        """, (cid, json.dumps(payload, ensure_ascii=False)))
        conn.commit()
    return cid


def delete_character(char_id: str) -> None:
    cid = validate_id(char_id)
    with _connect() as conn, conn.cursor() as cur:
        cur.execute(f"DELETE FROM {_TABLE} WHERE id = %s", (cid,))
        if cur.rowcount == 0:
            conn.rollback()
            raise CharacterError(f"Персонажа «{char_id}» не знайдено.")
        conn.commit()


def _unique_id(base: str, cur) -> str:
    """Підібрати вільний ідентифікатор: «makosh», «makosh-2», «makosh-3»…"""
    stem = validate_id(base)
    cur.execute(f"SELECT 1 FROM {_TABLE} WHERE id = %s", (stem,))
    if cur.fetchone() is None:
        return stem
    for n in range(2, 1000):
        candidate = f"{stem}-{n}"[:64].strip("-")
        cur.execute(f"SELECT 1 FROM {_TABLE} WHERE id = %s", (candidate,))
        if cur.fetchone() is None:
            return candidate
    raise CharacterError("Не вдалося підібрати вільний ідентифікатор.")


def clone_character(char_id: str) -> tuple[str, str]:
    """Створити копію персонажа з усім сценарієм. Повертає (новий_id, назва)."""
    raw = read_raw(char_id)
    with _connect() as conn, conn.cursor() as cur:
        new_id = _unique_id(f"{validate_id(char_id)}-kopiia", cur)
        name = (raw.get("display_name") or char_id).strip()
        payload = dict(raw)
        payload["display_name"] = f"{name} (копія)"
        payload["id"] = new_id
        cur.execute(f"""
            INSERT INTO {_TABLE} (id, data, updated_at) VALUES (%s, %s, now())
        """, (new_id, json.dumps(payload, ensure_ascii=False)))
        conn.commit()
    return new_id, payload["display_name"]


# ── початкове наповнення ────────────────────────────────────────────────────

def seed_from_files_if_empty() -> None:
    """Якщо таблиця порожня — наповнити її наявними characters/*.yaml.

    Спрацьовує один раз (при першому зверненні до порожньої БД). Без цього
    персонажі, що йдуть у репозиторії (Домовичок, Водяник, Повітруля), просто
    «зникли» б одразу після першого ввімкнення storage.render: yes — до першої
    ручної дії в редакторі БД була б порожньою.
    """
    import yaml

    from .characters import characters_dir

    with _connect() as conn, conn.cursor() as cur:
        cur.execute(f"SELECT count(*) FROM {_TABLE}")
        (count,) = cur.fetchone()
        if count:
            return

        directory = characters_dir()
        if not directory.exists():
            return

        seeded = 0
        for path in sorted(directory.glob("*.yaml")):
            try:
                with path.open("r", encoding="utf-8") as fh:
                    raw = yaml.safe_load(fh) or {}
            except (OSError, yaml.YAMLError):
                continue
            if not isinstance(raw, dict):
                continue
            payload = dict(raw)
            payload["id"] = path.stem
            cur.execute(f"""
                INSERT INTO {_TABLE} (id, data) VALUES (%s, %s)
                ON CONFLICT (id) DO NOTHING
            """, (path.stem, json.dumps(payload, ensure_ascii=False)))
            seeded += 1
        conn.commit()
        if seeded:
            log.info("PostgreSQL: імпортовано %d персонаж(ів) із characters/*.yaml", seeded)

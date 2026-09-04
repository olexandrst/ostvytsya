"""Автентифікація веб-панелі: один адміністратор у SQLite + підписана сесійна кука.

Обліковий запис живе в таблиці `users` спільної бази панелі
(domovyk_quest/db.py) — не в змінних середовища. Змінні потрібні лише для
ПЕРШОГО створення адміністратора (коли таблиця порожня):
    OSTVYTSYA_WEB_USER          — логін (типово «admin»)
    OSTVYTSYA_WEB_PASSWORD      — початковий пароль у відкритому вигляді
    OSTVYTSYA_WEB_PASSWORD_HASH — АБО готовий хеш «pbkdf2_sha256$ітерації$сіль$хеш»
Якщо не задано жодного — пароль генерується випадково, друкується в лог і
кладеться в data/initial-admin-password.txt (файл зникає після першої зміни
пароля в панелі). Далі пароль змінюється лише через панель (/account) або
`python -m web --set-admin-password`; змінні середовища на нього більше не
впливають, тож старий пароль у .env не «відкотить» нового.

    OSTVYTSYA_WEB_SECRET        — ключ підпису сесійної куки; якщо не задано,
                                  генерується один раз і зберігається в базі
                                  (сесії переживають перезапуск сервера).

Пароль ніколи не порівнюється звичайним «==» — лише порівнянням сталого часу,
щоб зловмисник не міг підібрати його, вимірюючи час відповіді.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import os
import secrets
import time
from typing import Optional

from domovyk_quest import db

log = logging.getLogger("ostvytsya.auth")

_ALGO = "pbkdf2_sha256"
_ITERATIONS = 240_000

MIN_PASSWORD_LENGTH = 8


def hash_password(password: str, *, salt: str | None = None,
                  iterations: int = _ITERATIONS) -> str:
    """Порахувати хеш пароля у форматі «pbkdf2_sha256$ітерації$сіль$хеш»."""
    salt = salt or secrets.token_hex(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"),
                             salt.encode("utf-8"), iterations)
    digest = base64.b64encode(dk).decode("ascii")
    return f"{_ALGO}${iterations}${salt}${digest}"


def verify_password(password: str, stored: str) -> bool:
    """Перевірити пароль проти збереженого хешу (порівняння сталого часу)."""
    try:
        algo, iterations, salt, _digest = stored.split("$", 3)
        if algo != _ALGO:
            return False
        candidate = hash_password(password, salt=salt, iterations=int(iterations))
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(candidate, stored)


# Хеш-«манекен»: коли логіна не існує, все одно рахуємо pbkdf2, щоб час
# відповіді не видавав, чи є такий користувач.
_DUMMY_HASH = hash_password(secrets.token_urlsafe(16))


class AuthError(Exception):
    """Помилка конфігурації доступу."""


class Auth:
    """Користувачі панелі в SQLite. За задумом — один адміністратор."""

    def __init__(self) -> None:
        self.user = (os.environ.get("OSTVYTSYA_WEB_USER") or "admin").strip() or "admin"

    # ── створення адміністратора ──────────────────────────────────────────

    def ensure_admin(self) -> Optional[str]:
        """Створити адміністратора, якщо в базі ще немає жодного користувача.

        Повертає ЗГЕНЕРОВАНИЙ пароль, якщо довелося вигадати його самим
        (ні OSTVYTSYA_WEB_PASSWORD, ні …_HASH не задано); інакше None.
        """
        with db.connect() as conn:
            (count,) = conn.execute("SELECT count(*) FROM users").fetchone()
            if count:
                return None
            stored = (os.environ.get("OSTVYTSYA_WEB_PASSWORD_HASH") or "").strip()
            plain = os.environ.get("OSTVYTSYA_WEB_PASSWORD") or ""
            generated: Optional[str] = None
            if stored:
                password_hash = stored
            elif plain:
                password_hash = hash_password(plain)
            else:
                generated = secrets.token_urlsafe(12)
                password_hash = hash_password(generated)
            now = time.time()
            conn.execute(
                "INSERT INTO users (username, password_hash, created_at, updated_at) "
                "VALUES (?, ?, ?, ?)",
                (self.user, password_hash, now, now),
            )
        log.info("Створено адміністратора «%s»", self.user)
        return generated

    @property
    def configured(self) -> bool:
        try:
            with db.connect() as conn:
                (count,) = conn.execute("SELECT count(*) FROM users").fetchone()
            return bool(count)
        except Exception:  # noqa: BLE001
            return False

    # ── перевірка ─────────────────────────────────────────────────────────

    def authenticate(self, user: str, password: str) -> Optional[str]:
        """Повернути канонічний логін, якщо пара логін/пароль правильна, інакше None."""
        username = (user or "").strip()
        stored: Optional[str] = None
        if username:
            try:
                with db.connect() as conn:
                    row = conn.execute(
                        "SELECT username, password_hash FROM users WHERE username = ?",
                        (username,),
                    ).fetchone()
            except Exception:  # noqa: BLE001
                log.exception("Не вдалося прочитати користувача з бази")
                row = None
            if row is not None:
                stored = str(row["password_hash"])
                username = str(row["username"])
        ok = verify_password(password or "", stored or _DUMMY_HASH)
        return username if (ok and stored is not None) else None

    def check(self, user: str, password: str) -> bool:
        return self.authenticate(user, password) is not None

    # ── зміна пароля ──────────────────────────────────────────────────────

    def set_password(self, username: str, new_password: str) -> None:
        if len(new_password or "") < MIN_PASSWORD_LENGTH:
            raise AuthError(f"Пароль має бути щонайменше {MIN_PASSWORD_LENGTH} символів.")
        with db.connect() as conn:
            cur = conn.execute(
                "UPDATE users SET password_hash = ?, updated_at = ? WHERE username = ?",
                (hash_password(new_password), time.time(), (username or "").strip()),
            )
            if cur.rowcount == 0:
                raise AuthError(f"Користувача «{username}» не знайдено.")
        log.info("Пароль користувача «%s» змінено", username)


def session_secret() -> str:
    """Ключ підпису сесійної куки.

    Пріоритет — OSTVYTSYA_WEB_SECRET. Якщо не заданий — генеруємо один раз і
    зберігаємо в базі, тож сесії переживають перезапуск сервера. І лише якщо
    база недоступна — тимчасовий ключ (після перезапуску всім треба
    перелогінитись).
    """
    key = (os.environ.get("OSTVYTSYA_WEB_SECRET") or "").strip()
    if key:
        return key
    try:
        stored = db.get_setting("session_secret")
        if stored:
            return stored
        key = secrets.token_urlsafe(48)
        db.set_setting("session_secret", key)
        return key
    except Exception:  # noqa: BLE001
        log.exception("Не вдалося зберегти ключ сесії в базі — використовую тимчасовий")
        return secrets.token_urlsafe(48)

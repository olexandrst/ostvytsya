"""Автентифікація веб-додатка: логін/пароль + підписана сесійна кука.

Облікові дані беруться зі змінних середовища (файл .env):
    OSTVYTSYA_WEB_USER      — логін (типово «admin»)
    OSTVYTSYA_WEB_PASSWORD  — пароль у відкритому вигляді
    OSTVYTSYA_WEB_PASSWORD_HASH — АБО ж готовий хеш «pbkdf2_sha256$ітерації$сіль$хеш»
    OSTVYTSYA_WEB_SECRET    — ключ для підпису сесійної куки

Пароль ніколи не порівнюється звичайним «==» — лише порівнянням сталого часу,
щоб зловмисник не міг підібрати його, вимірюючи час відповіді.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import secrets

_ALGO = "pbkdf2_sha256"
_ITERATIONS = 240_000


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


class AuthError(Exception):
    """Помилка конфігурації доступу."""


class Auth:
    """Перевірка облікових даних єдиного користувача."""

    def __init__(self) -> None:
        self.user = (os.environ.get("OSTVYTSYA_WEB_USER") or "admin").strip()
        stored = (os.environ.get("OSTVYTSYA_WEB_PASSWORD_HASH") or "").strip()
        plain = os.environ.get("OSTVYTSYA_WEB_PASSWORD") or ""
        if stored:
            self.password_hash = stored
        elif plain:
            self.password_hash = hash_password(plain)
        else:
            self.password_hash = ""

    @property
    def configured(self) -> bool:
        return bool(self.password_hash)

    def check(self, user: str, password: str) -> bool:
        if not self.configured:
            return False
        # Логін теж порівнюємо сталим часом, щоб не підказувати його існування.
        user_ok = hmac.compare_digest((user or "").strip(), self.user)
        pass_ok = verify_password(password or "", self.password_hash)
        return user_ok and pass_ok


def session_secret() -> str:
    """Ключ підпису сесійної куки.

    Якщо не заданий — генеруємо тимчасовий: додаток працює, але після
    перезапуску всі сесії стають недійсними (користувачам треба перелогінитись).
    """
    key = (os.environ.get("OSTVYTSYA_WEB_SECRET") or "").strip()
    return key or secrets.token_urlsafe(48)

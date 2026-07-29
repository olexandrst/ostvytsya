"""Читання файлу .env без зовнішніх залежностей.

Потрібне, щоб ключі працювали однаково на Linux/macOS і на Windows: у PowerShell
немає `export $(grep ...)`, тож покладатися на ручний експорт змінних не можна —
додаток читає .env сам.

Справжні змінні середовища мають ПРІОРИТЕТ над файлом: якщо змінна вже задана в
оточенні, .env її не перетирає (якщо не попросити override=True).
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Iterable, Optional

DEFAULT_NAMES = (".env",)


def _project_root() -> Path:
    return Path(__file__).resolve().parent.parent


def candidate_paths(explicit: Optional[str | os.PathLike] = None) -> list[Path]:
    """Де шукати .env: явний шлях → поточна тека → корінь проєкту."""
    if explicit:
        return [Path(explicit)]
    out: list[Path] = []
    for name in DEFAULT_NAMES:
        out.append(Path.cwd() / name)
        out.append(_project_root() / name)
    # Прибрати дублікати, зберігши порядок.
    seen: set[Path] = set()
    uniq: list[Path] = []
    for p in out:
        rp = p.resolve()
        if rp not in seen:
            seen.add(rp)
            uniq.append(p)
    return uniq


def parse_env_text(text: str) -> dict[str, str]:
    """Розібрати вміст .env у словник."""
    data: dict[str, str] = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):        # сумісність із bash-стилем
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not key:
            continue
        value = value.strip()
        # Значення в лапках беремо як є; інакше відрізаємо інлайн-коментар.
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        else:
            hash_pos = value.find(" #")
            if hash_pos >= 0:
                value = value[:hash_pos].rstrip()
        data[key] = value
    return data


def load_env_file(path: Optional[str | os.PathLike] = None, *,
                  override: bool = False) -> tuple[Optional[Path], list[str]]:
    """Завантажити .env у середовище процесу.

    Повертає (шлях_знайденого_файлу, список_застосованих_ключів).
    Якщо файл не знайдено — (None, []). Порожні значення (напр. «KEY=») не
    застосовуються: типовий приклад .env лишає їх незаповненими.
    """
    for candidate in candidate_paths(path):
        try:
            if not candidate.is_file():
                continue
            text = candidate.read_text(encoding="utf-8-sig")
        except OSError:
            continue

        applied: list[str] = []
        for key, value in parse_env_text(text).items():
            if not value:
                continue
            if not override and os.environ.get(key):
                continue
            os.environ[key] = value
            applied.append(key)
        return candidate, applied
    return None, []


def mask(value: str, keep: int = 6) -> str:
    """Замаскувати секрет для показу в логах: «sk-proj…（прих.）»."""
    if not value:
        return "—"
    return value[:keep] + "…" + f"({len(value)} симв.)"


def describe(keys: Iterable[str]) -> str:
    keys = list(keys)
    return ", ".join(keys) if keys else "нічого нового"

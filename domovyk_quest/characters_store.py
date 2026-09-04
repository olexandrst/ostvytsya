"""Єдина точка входу для веб-режиму: збереження персонажів.

Бекенд обирає config.storage_backend_name() (config.yaml → storage.backend,
або змінна OSTVYTSYA_STORAGE_BACKEND):
    sqlite      (типово) → таблиця characters у data/ostvytsya.db
                          (domovyk_quest.characters_sqlite)
    files                → characters/*.yaml, як було спочатку
                          (domovyk_quest.characters)
    postgresql           → Render Managed PostgreSQL, DATABASE_URL
                          (domovyk_quest.characters_pg)

Веб-режим (web/app.py) імпортує персонажів ЛИШЕ звідси, а не з бекендів
напряму — так перемикання не вимагає жодних змін у решті коду.

Функції build_character/validate_id/slugify/CharacterError та списки голосів
не залежать від бекенду (це чиста логіка над словником), тож просто
переекспортуються з characters.py без обгортки.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Optional

from . import characters as _fs
from .characters import (  # noqa: F401 — backend-agnostic реекспорт
    CharacterError,
    GEMINI_VOICE_LABELS,
    GEMINI_VOICES,
    OPENAI_VOICES,
    PROVIDERS,
    build_character,
    slugify,
    validate_id,
)
from .config import storage_backend_name


def storage_backend() -> str:
    """Назва активного бекенду: "sqlite" | "files" | "postgresql"."""
    return storage_backend_name()


def _pg():
    from . import characters_pg
    return characters_pg


def _sqlite():
    from . import characters_sqlite
    return characters_sqlite


def list_characters(root: Optional[Path] = None) -> list[dict[str, Any]]:
    backend = storage_backend()
    if backend == "files":
        return _fs.list_characters(root)
    if backend == "postgresql":
        return _pg().list_characters()
    return _sqlite().list_characters()


def read_raw(char_id: str, root: Optional[Path] = None) -> dict[str, Any]:
    backend = storage_backend()
    if backend == "files":
        return _fs.read_raw(char_id, root)
    if backend == "postgresql":
        return _pg().read_raw(char_id)
    return _sqlite().read_raw(char_id)


def save_raw(char_id: str, data: dict[str, Any], *, create: bool = False,
             root: Optional[Path] = None) -> str:
    backend = storage_backend()
    if backend == "files":
        return _fs.save_raw(char_id, data, create=create, root=root)
    if backend == "postgresql":
        return _pg().save_raw(char_id, data, create=create)
    return _sqlite().save_raw(char_id, data, create=create)


def delete_character(char_id: str, root: Optional[Path] = None) -> None:
    backend = storage_backend()
    if backend == "files":
        _fs.delete_character(char_id, root)
    elif backend == "postgresql":
        _pg().delete_character(char_id)
    else:
        _sqlite().delete_character(char_id)


def clone_character(char_id: str, root: Optional[Path] = None) -> tuple[str, str]:
    backend = storage_backend()
    if backend == "files":
        return _fs.clone_character(char_id, root)
    if backend == "postgresql":
        return _pg().clone_character(char_id)
    return _sqlite().clone_character(char_id)

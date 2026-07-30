"""Єдина точка входу для веб-режиму: збереження персонажів (файли або PostgreSQL).

Вибір бекенду — config.yaml → storage.render: yes/no (типово no):
    no  (типово)  → characters/*.yaml, як і раніше (domovyk_quest.characters).
    yes            → Render Managed PostgreSQL (domovyk_quest.characters_pg).

Веб-режим (web/app.py) імпортує персонажів ЛИШЕ звідси, а не з characters.py
чи characters_pg.py напряму — так перемикання бекенду не вимагає жодних змін
у решті коду. Консольний режим цей модуль не використовує: він завжди читає
свій файл персонажа напряму (domovyk_quest.config._load_character), незалежно
від storage.render, — на Raspberry Pi файлова система стабільна й постійна,
жодної причини заводити туди PostgreSQL немає.

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
from .config import render_storage_enabled

# characters.load_character() НЕ реекспортуємо: він завжди читає файл напряму
# (fs read_raw), в обхід диспетчера. Використовуй read_raw()+build_character()
# звідси — вони поважають storage.render, як і решта цього модуля.


def storage_backend() -> str:
    """Назва активного бекенду — для діагностики (лог, /api/health)."""
    return "postgresql" if render_storage_enabled() else "files"


def _pg():
    from . import characters_pg
    return characters_pg


def list_characters(root: Optional[Path] = None) -> list[dict[str, Any]]:
    if render_storage_enabled():
        return _pg().list_characters()
    return _fs.list_characters(root)


def read_raw(char_id: str, root: Optional[Path] = None) -> dict[str, Any]:
    if render_storage_enabled():
        return _pg().read_raw(char_id)
    return _fs.read_raw(char_id, root)


def save_raw(char_id: str, data: dict[str, Any], *, create: bool = False,
             root: Optional[Path] = None) -> str:
    if render_storage_enabled():
        return _pg().save_raw(char_id, data, create=create)
    return _fs.save_raw(char_id, data, create=create, root=root)


def delete_character(char_id: str, root: Optional[Path] = None) -> None:
    if render_storage_enabled():
        _pg().delete_character(char_id)
        return
    _fs.delete_character(char_id, root)


def clone_character(char_id: str, root: Optional[Path] = None) -> tuple[str, str]:
    if render_storage_enabled():
        return _pg().clone_character(char_id)
    return _fs.clone_character(char_id, root)

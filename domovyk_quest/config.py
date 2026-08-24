"""Модель персонажа та спільні дрібниці конфігурації.

Персонаж живе у `characters/<id>.yaml` (персона, голос, кодові слова,
запитання з підказками, фінальне слово) — той самий файл читає і веб-режим,
і мобільний застосунок.

Раніше тут жив ще й рантайм консольного агента (аудіо, режим пробудження,
тайм-аути) — його прибрано разом із самим консольним режимом. Лишилось те,
що справді потрібно вебу: [Character]/[Question], [_build] і читання
`config.yaml` заради однієї секції `storage:`.
"""

from __future__ import annotations

import functools
import os
from dataclasses import dataclass, field, fields
from pathlib import Path
from typing import Any, Optional

import yaml


@dataclass(frozen=True)
class Question:
    id: str
    text: str
    accepted: tuple[str, ...] = ()
    hints: tuple[str, ...] = ()
    reveal: str = ""


@dataclass(frozen=True)
class Character:
    id: str
    display_name: str
    voice: str
    language: str
    wake_words: tuple[str, ...]
    win_word: str
    persona: str
    style: tuple[str, ...]
    intro: str
    questions: tuple[Question, ...]
    win: str
    goodbye: str = ""
    # Суворі заборони/надзавдання — виводяться НА ПОЧАТКУ системної інструкції
    # (найвищий пріоритет). Напр., для квесту з фізичним пошуком: не озвучувати
    # слова-відповіді, а лише слухати й підтверджувати.
    directives: tuple[str, ...] = ()
    fallbacks: dict[str, str] = field(default_factory=dict)
    # ── Веб-режим ────────────────────────────────────────────────────────────
    # Якою моделлю персонаж говорить у браузері: "openai" (Realtime) або
    # "google" (Gemini Live). Консольна лялька завжди працює через Gemini.
    provider: str = "openai"
    # Голоси OpenAI інші, ніж у Gemini, тож зберігаємо їх окремим полем — так
    # один і той самий персонаж працює в обох режимах (консоль + веб).
    openai_voice: str = "marin"
    # Швидкість мовлення у веб-режимі (1.0 = звичайна). Підтримує OpenAI Realtime.
    speech_speed: float = 1.0
    # Якщо задано — цей текст іде в модель ЯК Є, замість інструкції, зібраної з
    # persona/style/questions. Так веб-редактор може створювати персонажів
    # довільним промптом, не описуючи повний YAML-сценарій.
    system_prompt: str = ""


class ConfigError(Exception):
    """Помилка у конфігурації."""


# ── Завантаження ─────────────────────────────────────────────────────────────

def _build(cls, data: dict[str, Any]):
    """Зібрати dataclass із dict, ігноруючи зайві ключі, з приведенням типів."""
    kwargs: dict[str, Any] = {}
    known = {f.name: f for f in fields(cls)}
    for name, f in known.items():
        if name not in data:
            continue
        value = data[name]
        if value is None:
            continue
        # tuple-поля (список рядків тощо)
        if f.type and "tuple" in str(f.type) and isinstance(value, list):
            value = tuple(value)
        kwargs[name] = value
    return cls(**kwargs)


# ── Сховище персонажів веб-режиму (файли або Render Managed PostgreSQL) ───────

@functools.lru_cache(maxsize=8)
def _read_top_level_yaml(path_str: str) -> dict[str, Any]:
    path = Path(path_str)
    if not path.exists():
        return {}
    try:
        with path.open("r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh) or {}
    except (OSError, yaml.YAMLError):
        return {}
    return data if isinstance(data, dict) else {}


def render_storage_enabled(config_path: Optional[str | os.PathLike] = None) -> bool:
    """Чи зберігати персонажів веб-режиму в Render Managed PostgreSQL.

    Читається з config.yaml → storage.render: yes/no. Типово (секції немає,
    файла немає, або render: no) — стара поведінка: персонажі зберігаються як
    файли characters/*.yaml, як і раніше.

    Це навмисно ЛЕГКА перевірка без повної валідації AppConfig: веб-режим
    працює з багатьма персонажами одночасно, а не з одним обраним, як консоль,
    тож переганяти цей прапорець крізь load_config() (який вимагає конкретного
    character_file) було б зайвою залежністю.

    Результат кешується (config.yaml не перечитується на кожен запит) — зміна
    значення застосовується після перезапуску, як і решта конфігурації.
    """
    path = Path(config_path) if config_path else (
        Path(__file__).resolve().parent.parent / "config.yaml"
    )
    raw = _read_top_level_yaml(str(path))
    storage = raw.get("storage")
    if not isinstance(storage, dict):
        return False
    return bool(storage.get("render", False))

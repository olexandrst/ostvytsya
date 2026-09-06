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
    # ── Поведінка сесії в мобільному застосунку ─────────────────────────────
    # Слова від ГОСТЕЙ, що завершують сесію (напр. «Каліпсо» для екскурсії):
    # почувши одне з них, застосунок дає персонажу попрощатись і закриває сесію.
    stop_words: tuple[str, ...] = ()
    # Прокидатись від БУДЬ-ЯКОГО голосу, а не лише від кодового слова
    # (персонаж-зазивайло на вхідній вежі).
    wake_on_voice: bool = False
    # Скільки секунд тиші завершують сесію (None — типова константа застосунку).
    inactivity_timeout_s: Optional[int] = None
    # Час очікування відповіді, секунд: скільки персонаж мовчки слухає людей
    # після своєї репліки, перш ніж застосунок попросить його продовжити
    # самому (повторити питання, дати підказку, вести розповідь далі) — бо
    # модель сама по себе говорить лише у відповідь. 0 — без обмеження.
    answer_wait_s: int = 8
    # Стискати контекст розмови (Gemini Live contextWindowCompression з явними
    # порогами, див. mobile constants.dart): персонаж пам'ятає лише останні
    # ~8–15 хвилин розмови, зате довга сесія коштує у 2–3 рази дешевше — бо
    # модель на кожному ході перечитує (і оплачує) всю історію. Вимикай для
    # квестів, де треба пам'ятати все сказане від початку (Повітруля веде лік
    # знайдених слів). Вимкнено = типова поведінка Google: стискання лише при
    # переповненні вікна моделі, сесія необмежена.
    context_compression: bool = True


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


STORAGE_BACKENDS = ("sqlite", "files", "postgresql")

_BACKEND_ALIASES = {
    "postgres": "postgresql", "pg": "postgresql", "render": "postgresql",
    "yaml": "files", "file": "files", "fs": "files",
    "sqlite3": "sqlite", "db": "sqlite",
}


def storage_backend_name(config_path: Optional[str | os.PathLike] = None) -> str:
    """Де веб-режим зберігає персонажів: "sqlite" (типово), "files" чи "postgresql".

    Джерела, за пріоритетом:
      1. змінна середовища OSTVYTSYA_STORAGE_BACKEND (зручно на хостингу, де
         config.yaml — частина репозиторію);
      2. config.yaml → storage.backend;
      3. старий прапорець config.yaml → storage.render: yes → "postgresql"
         (лишено для сумісності);
      4. інакше — "sqlite".

    Це навмисно ЛЕГКА перевірка: результат кешується (config.yaml не
    перечитується на кожен запит) — зміна застосовується після перезапуску.
    """
    explicit = (os.environ.get("OSTVYTSYA_STORAGE_BACKEND") or "").strip().lower()
    if explicit:
        explicit = _BACKEND_ALIASES.get(explicit, explicit)
        if explicit in STORAGE_BACKENDS:
            return explicit
    path = Path(config_path) if config_path else (
        Path(__file__).resolve().parent.parent / "config.yaml"
    )
    raw = _read_top_level_yaml(str(path))
    storage = raw.get("storage")
    if not isinstance(storage, dict):
        return "sqlite"
    backend = str(storage.get("backend") or "").strip().lower()
    backend = _BACKEND_ALIASES.get(backend, backend)
    if backend in STORAGE_BACKENDS:
        return backend
    if storage.get("render", False):
        return "postgresql"
    return "sqlite"


def render_storage_enabled(config_path: Optional[str | os.PathLike] = None) -> bool:
    """Чи персонажі веб-режиму живуть у PostgreSQL (див. storage_backend_name)."""
    return storage_backend_name(config_path) == "postgresql"

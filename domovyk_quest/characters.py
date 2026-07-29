"""Спільний репозиторій персонажів: читання, створення, редагування, видалення.

Єдине джерело правди для ОБОХ режимів роботи:
  * консольний агент (Gemini Live) — читає персонажа звідси через load_config();
  * веб-додаток (OpenAI Realtime) — показує, редагує й створює персонажів тут же.

Персонаж = один YAML-файл у теці characters/. Формат не змінюється, тож усі
наявні сценарії (Домовичок, Водяник, Повітруля) працюють у веб-режимі як є.
"""

from __future__ import annotations

import os
import re
import tempfile
from pathlib import Path
from typing import Any, Optional

import yaml

from .config import Character, ConfigError, _build, Question

# Голоси OpenAI Realtime. marin і cedar — найякісніші (рекомендація OpenAI).
OPENAI_VOICES = (
    "marin", "cedar", "alloy", "ash", "ballad",
    "coral", "echo", "sage", "shimmer", "verse",
)

# Голоси Gemini Native Audio (для консольного режиму).
GEMINI_VOICES = (
    "Charon", "Enceladus", "Aoede", "Leda", "Laomedeia", "Pulcherrima",
    "Autonoe", "Zephyr", "Sadachbita", "Kore", "Puck", "Fenrir",
)

_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")


class CharacterError(Exception):
    """Некоректний персонаж або неприпустима операція над ним."""


def characters_dir(root: Optional[Path] = None) -> Path:
    """Тека з персонажами (поруч із config.yaml проєкту)."""
    base = root or Path(__file__).resolve().parent.parent
    return base / "characters"


def validate_id(char_id: str) -> str:
    """Перевірити ідентифікатор персонажа.

    Захищає від виходу за межі теки (path traversal): дозволені лише малі
    латинські літери, цифри, дефіс і підкреслення.
    """
    cid = (char_id or "").strip().lower()
    if not _ID_RE.match(cid):
        raise CharacterError(
            "Ідентифікатор має складатися з малих латинських літер, цифр, "
            "дефіса чи підкреслення (напр. «povitrulya»)."
        )
    return cid


def character_path(char_id: str, root: Optional[Path] = None) -> Path:
    return characters_dir(root) / f"{validate_id(char_id)}.yaml"


def slugify(name: str) -> str:
    """Зробити безпечний ідентифікатор із назви (для нових персонажів)."""
    translit = {
        "а": "a", "б": "b", "в": "v", "г": "h", "ґ": "g", "д": "d", "е": "e",
        "є": "ie", "ж": "zh", "з": "z", "и": "y", "і": "i", "ї": "i", "й": "i",
        "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r",
        "с": "s", "т": "t", "у": "u", "ф": "f", "х": "kh", "ц": "ts", "ч": "ch",
        "ш": "sh", "щ": "shch", "ь": "", "ю": "iu", "я": "ia", "'": "", "’": "",
    }
    out = "".join(translit.get(ch, ch) for ch in (name or "").strip().lower())
    out = re.sub(r"[^a-z0-9]+", "-", out).strip("-")
    return out[:64] or "character"


# ── читання ──────────────────────────────────────────────────────────────────

def read_raw(char_id: str, root: Optional[Path] = None) -> dict[str, Any]:
    """Сирий YAML персонажа як словник."""
    path = character_path(char_id, root)
    if not path.exists():
        raise CharacterError(f"Персонажа «{char_id}» не знайдено.")
    with path.open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    if not isinstance(data, dict):
        raise CharacterError(f"Файл персонажа «{char_id}» пошкоджено.")
    return data


def build_character(raw: dict[str, Any]) -> Character:
    """Зібрати об'єкт Character із сирого словника (як це робить load_config)."""
    questions = tuple(
        _build(Question, q) for q in raw.get("questions", []) if isinstance(q, dict)
    )
    data = dict(raw)
    data["questions"] = questions
    try:
        return _build(Character, data)
    except TypeError as exc:
        raise CharacterError(f"Некоректний персонаж: {exc}") from exc


def load_character(char_id: str, root: Optional[Path] = None) -> Character:
    return build_character(read_raw(char_id, root))


def list_characters(root: Optional[Path] = None) -> list[dict[str, Any]]:
    """Короткий опис усіх персонажів для списку у вебі."""
    out: list[dict[str, Any]] = []
    directory = characters_dir(root)
    if not directory.exists():
        return out
    for path in sorted(directory.glob("*.yaml")):
        char_id = path.stem
        try:
            raw = read_raw(char_id, root)
        except (CharacterError, yaml.YAMLError):
            continue  # пошкоджений файл не має ламати весь список
        out.append({
            "id": char_id,
            "display_name": raw.get("display_name") or char_id,
            "voice": raw.get("voice") or "",
            "openai_voice": raw.get("openai_voice") or "marin",
            "wake_words": list(raw.get("wake_words") or []),
            "win_word": raw.get("win_word") or "",
            "questions": len(raw.get("questions") or []),
            "custom_prompt": bool((raw.get("system_prompt") or "").strip()),
        })
    return out


# ── запис ────────────────────────────────────────────────────────────────────

def _check_payload(data: dict[str, Any]) -> None:
    if not (data.get("display_name") or "").strip():
        raise CharacterError("Вкажи назву персонажа.")
    voice = (data.get("openai_voice") or "").strip()
    if voice and voice not in OPENAI_VOICES:
        raise CharacterError(f"Невідомий голос OpenAI: «{voice}».")
    has_prompt = bool((data.get("system_prompt") or "").strip())
    has_questions = bool(data.get("questions"))
    if not has_prompt and not has_questions:
        raise CharacterError(
            "Персонаж має містити або текст промпту, або хоча б одну загадку."
        )
    try:
        speed = float(data.get("speech_speed") or 1.0)
    except (TypeError, ValueError):
        raise CharacterError("Швидкість мовлення має бути числом.") from None
    if not 0.25 <= speed <= 2.0:
        raise CharacterError("Швидкість мовлення має бути в межах 0.25–2.0.")


def _render_yaml(path: Path, payload: dict[str, Any]) -> str:
    """Зібрати текст YAML для запису.

    Файли персонажів рясно коментовані (пояснення сценарію, застереження про
    спойлери), а звичайний dump ці коментарі знищує. Тому наявний файл
    оновлюємо «на місці» через ruamel.yaml — він зберігає коментарі, порядок
    ключів і блоки |. Якщо ruamel не встановлено або файл новий — звичайний dump.
    """
    if path.exists():
        try:
            from ruamel.yaml import YAML  # опційна залежність веб-режиму
        except ImportError:
            pass
        else:
            import io

            ry = YAML()
            ry.preserve_quotes = True
            ry.width = 4096  # не переносити довгі рядки сценарію
            ry.indent(mapping=2, sequence=4, offset=2)
            with path.open("r", encoding="utf-8") as fh:
                doc = ry.load(fh) or {}
            # Чіпаємо ТІЛЬКИ те, що справді змінилося: якщо переприсвоїти ключ
            # тим самим значенням, ruamel перебудує його вузол і загубить
            # прив'язані коментарі та форматування (блоки |, лапки, відступи).
            for key, value in payload.items():
                if key not in doc or doc[key] != value:
                    doc[key] = value
            for key in list(doc.keys()):        # прибрати те, чого більше немає
                if key not in payload:
                    del doc[key]
            buf = io.StringIO()
            ry.dump(doc, buf)
            return buf.getvalue()

    return yaml.safe_dump(payload, allow_unicode=True, sort_keys=False,
                          width=100, default_flow_style=False)


def save_raw(char_id: str, data: dict[str, Any], *, create: bool = False,
             root: Optional[Path] = None) -> str:
    """Записати персонажа у YAML (атомарно), повернути його id."""
    cid = validate_id(char_id)
    _check_payload(data)
    path = character_path(cid, root)
    if create and path.exists():
        raise CharacterError(f"Персонаж «{cid}» уже існує.")
    if not create and not path.exists():
        raise CharacterError(f"Персонажа «{cid}» не знайдено.")

    payload = dict(data)
    payload["id"] = cid
    # Перевіряємо, що з цього справді збирається персонаж, ще ДО запису на диск.
    build_character(payload)

    path.parent.mkdir(parents=True, exist_ok=True)
    text = _render_yaml(path, payload)
    # Атомарний запис: спершу у тимчасовий файл поруч, потім підміна — щоб
    # консольний агент ніколи не прочитав напівзаписаний файл.
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    return cid


def unique_id(base: str, root: Optional[Path] = None) -> str:
    """Підібрати вільний ідентифікатор: «makosh», «makosh-2», «makosh-3»…"""
    stem = validate_id(base)
    if not character_path(stem, root).exists():
        return stem
    for n in range(2, 1000):
        candidate = f"{stem}-{n}"[:64].strip("-")
        if not character_path(candidate, root).exists():
            return candidate
    raise CharacterError("Не вдалося підібрати вільний ідентифікатор.")


def clone_character(char_id: str, root: Optional[Path] = None) -> tuple[str, str]:
    """Створити копію персонажа з усім сценарієм. Повертає (новий_id, назва)."""
    raw = read_raw(char_id, root)
    new_id = unique_id(f"{validate_id(char_id)}-kopiia", root)
    name = (raw.get("display_name") or char_id).strip()
    payload = dict(raw)
    payload["display_name"] = f"{name} (копія)"
    payload["id"] = new_id
    # Пишемо копію з нуля, а не поверх оригіналу, щоб не тягнути його коментарі
    # з чужим ім'ям персонажа у заголовку файлу.
    path = character_path(new_id, root)
    _check_payload(payload)
    build_character(payload)
    text = yaml.safe_dump(payload, allow_unicode=True, sort_keys=False,
                          width=100, default_flow_style=False)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    return new_id, payload["display_name"]


def delete_character(char_id: str, root: Optional[Path] = None) -> None:
    path = character_path(char_id, root)
    if not path.exists():
        raise CharacterError(f"Персонажа «{char_id}» не знайдено.")
    path.unlink()

"""Завантаження та валідація конфігурації квест-агента.

Конфіг живе у двох YAML-файлах:
  * config.yaml          — рантайм (аудіо, модель, режим пробудження, тайм-аути);
  * characters/<id>.yaml — персонаж і сценарій (персона, голос, кодові слова,
                           три загадки з підказками, фінальне слово).

Персонаж може перевизначати кілька рантайм-полів (наприклад, voice/language).
Усе зводиться в один незмінний об'єкт AppConfig.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field, fields, is_dataclass
from pathlib import Path
from typing import Any, Optional, Union

import yaml


# ── Рантайм-секції ───────────────────────────────────────────────────────────

@dataclass(frozen=True)
class GeminiCfg:
    api_key_env: str = "GEMINI_API_KEY"
    model: str = "gemini-2.5-flash-native-audio-preview-09-2025"
    api_version: str = "v1beta"


@dataclass(frozen=True)
class AudioCfg:
    input_device: Optional[Union[int, str]] = None
    output_device: Optional[Union[int, str]] = None
    input_sample_rate: int = 16000
    output_sample_rate: int = 24000
    input_block_ms: int = 32
    vad_rms_threshold: float = 350.0

    @property
    def input_block_frames(self) -> int:
        return int(self.input_sample_rate * self.input_block_ms / 1000)


@dataclass(frozen=True)
class WakeCfg:
    mode: str = "vosk"  # vosk | gemini | manual
    vosk_model_path: str = "models/vosk-model-small-uk"
    vosk_grammar: bool = False  # звузити розпізнавання до кодових слів (лише для слів у словнику Vosk)
    fuzzy: bool = True
    fuzzy_threshold: float = 0.70


@dataclass(frozen=True)
class SessionCfg:
    inactivity_timeout_s: float = 45.0
    max_duration_s: float = 300.0
    cooldown_s: float = 3.0
    greeting_on_wake: bool = True       # персонаж вітається першим одразу після кодового слова
    greeting_nudge_s: float = 4.0       # якщо мовчить — за стільки секунд повторити спонукання
    # Напівдуплекс: поки агент говорить, мікрофон не йде в модель (захист від
    # акустичного відлуння без апаратного AEC). Вимкни лише за наявності AEC,
    # щоб дозволити перебивання (barge-in).
    half_duplex: bool = True
    echo_guard_ms: int = 400  # пауза після мовлення агента перед відкриттям мікрофона


@dataclass(frozen=True)
class LoggingCfg:
    level: str = "INFO"
    transcript: bool = True
    file: bool = True          # писати також у файл ./logs/ostvytsya_YYYY-MM-DD.log
    dir: str = "logs"          # тека для лог-файлів


# ── Персонаж / сценарій ──────────────────────────────────────────────────────

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
    fallbacks: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class AppConfig:
    gemini: GeminiCfg
    audio: AudioCfg
    wake: WakeCfg
    session: SessionCfg
    logging: LoggingCfg
    character: Character

    @property
    def api_key(self) -> str:
        key = os.environ.get(self.gemini.api_key_env, "").strip()
        if not key:
            raise ConfigError(
                f"Не знайдено ключ API у змінній середовища "
                f"'{self.gemini.api_key_env}'. Встанови його:\n"
                f"    export {self.gemini.api_key_env}=...\n"
                f"Ключ можна отримати на https://aistudio.google.com/apikey"
            )
        return key


class ConfigError(Exception):
    """Помилка у конфігурації."""


# ── Завантаження ─────────────────────────────────────────────────────────────

def _read_yaml(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise ConfigError(f"Файл конфігурації не знайдено: {path}")
    with path.open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    if not isinstance(data, dict):
        raise ConfigError(f"Очікувався YAML-словник у {path}")
    return data


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


def load_config(
    config_path: str | os.PathLike = "config.yaml",
    character_path: Optional[str | os.PathLike] = None,
    *,
    overrides: Optional[dict[str, Any]] = None,
) -> AppConfig:
    """Завантажити рантайм + персонажа в єдиний AppConfig.

    overrides — пласкі перевизначення з CLI, напр. {"wake.mode": "manual"}.
    """
    overrides = overrides or {}
    root = Path(config_path).resolve().parent

    raw = _read_yaml(Path(config_path))

    gemini = _build(GeminiCfg, raw.get("gemini", {}))
    audio = _build(AudioCfg, raw.get("audio", {}))
    wake = _build(WakeCfg, raw.get("wake", {}))
    session = _build(SessionCfg, raw.get("session", {}))
    logging_cfg = _build(LoggingCfg, raw.get("logging", {}))

    # Який персонаж: CLI > config.yaml.
    char_file = character_path or raw.get("character_file")
    if not char_file:
        raise ConfigError("Не вказано персонажа: ні --character, ні character_file у config.yaml")
    char_path = Path(char_file)
    if not char_path.is_absolute():
        char_path = (root / char_path).resolve()

    character, char_raw = _load_character(char_path)

    cfg = AppConfig(
        gemini=gemini,
        audio=audio,
        wake=wake,
        session=session,
        logging=logging_cfg,
        character=character,
    )
    # Порядок пріоритету: CLI > персонаж > config.yaml. Персонаж може нести
    # власні рантайм-секції (напр. session:) — інший квест потребує інших пауз.
    cfg = _apply_overrides(cfg, _character_runtime_overrides(char_raw))
    cfg = _apply_overrides(cfg, overrides)
    _validate(cfg)
    return cfg


# Рантайм-секції, які файл персонажа може перевизначити поверх config.yaml.
_RUNTIME_SECTIONS = ("gemini", "audio", "wake", "session", "logging")


def _character_runtime_overrides(char_raw: dict[str, Any]) -> dict[str, Any]:
    """Зібрати з файлу персонажа пласкі 'секція.поле' рантайм-перевизначення."""
    out: dict[str, Any] = {}
    for section in _RUNTIME_SECTIONS:
        block = char_raw.get(section)
        if isinstance(block, dict):
            for key, value in block.items():
                out[f"{section}.{key}"] = value
    return out


def _load_character(path: Path) -> tuple[Character, dict[str, Any]]:
    """Повертає (персонаж, сирий YAML). Сирий словник потрібен для рантайм-
    перевизначень персонажа (напр. блок session:)."""
    raw = _read_yaml(path)
    questions = tuple(
        _build(Question, q) for q in raw.get("questions", []) if isinstance(q, dict)
    )
    data = dict(raw)
    data["questions"] = questions
    # Приведення списків до tuple виконує _build; fallbacks лишаємо dict.
    # Зайві ключі (рантайм-секції на кшталт session:) _build ігнорує.
    try:
        return _build(Character, data), raw
    except TypeError as exc:
        raise ConfigError(f"Некоректний файл персонажа {path}: {exc}") from exc


def _apply_overrides(cfg: AppConfig, overrides: dict[str, Any]) -> AppConfig:
    """Застосувати пласкі 'секція.поле' перевизначення, повернути новий AppConfig."""
    from dataclasses import replace

    sections = {
        "gemini": cfg.gemini,
        "audio": cfg.audio,
        "wake": cfg.wake,
        "session": cfg.session,
        "logging": cfg.logging,
        "character": cfg.character,
    }
    changed: dict[str, Any] = {}
    for dotted, value in overrides.items():
        if value is None or "." not in dotted:
            continue
        section, _, field_name = dotted.partition(".")
        if section not in sections:
            continue
        obj = changed.get(section, sections[section])
        if not is_dataclass(obj) or not any(f.name == field_name for f in fields(obj)):
            continue
        changed[section] = replace(obj, **{field_name: value})

    if not changed:
        return cfg
    return replace(cfg, **changed)


def _validate(cfg: AppConfig) -> None:
    if cfg.wake.mode not in {"vosk", "gemini", "manual"}:
        raise ConfigError(f"Невідомий wake.mode: {cfg.wake.mode!r} (vosk|gemini|manual)")
    if not cfg.character.wake_words:
        raise ConfigError("У персонажа має бути хоча б одне кодове слово (wake_words).")
    if not cfg.character.questions:
        raise ConfigError("У персонажа має бути хоча б одна загадка (questions).")
    if not cfg.character.win_word:
        raise ConfigError("У персонажа має бути фінальне слово (win_word).")

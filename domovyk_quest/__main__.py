"""Консольний запуск квест-агента.

Приклади:
    python -m domovyk_quest
    python -m domovyk_quest --character characters/vodyanyk.yaml
    python -m domovyk_quest --wake manual --once
    python -m domovyk_quest --list-devices
"""

from __future__ import annotations

import argparse
import asyncio
import sys

from .config import ConfigError, load_config


def _parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="domovyk_quest",
        description="Голосовий квест-агент парку «Оствиця» (Gemini Native Audio).",
    )
    p.add_argument("-c", "--config", default="config.yaml", help="шлях до config.yaml")
    p.add_argument("--character", help="шлях до файлу персонажа (перекриває config)")
    p.add_argument("--wake", choices=["vosk", "gemini", "manual"], help="режим пробудження")
    p.add_argument("--voice", help="голос Gemini (перекриває персонажа)")
    p.add_argument("--model", help="модель Gemini (перекриває config)")
    p.add_argument("--log-level", help="DEBUG|INFO|WARNING|ERROR")
    p.add_argument("--once", action="store_true", help="один квест і вихід")
    p.add_argument("--calibrate", action="store_true",
                   help="показати, як детектор чує кодове слово (для налаштування wake_words)")
    p.add_argument("--list-devices", action="store_true", help="показати аудіопристрої й вийти")
    return p.parse_args(argv)


def _setup_logging(cfg) -> None:
    from .logsetup import configure_logging
    configure_logging(cfg.level, to_file=cfg.file, log_dir=cfg.dir)


def main(argv=None) -> int:
    args = _parse_args(argv)

    # Читаємо .env самі: у PowerShell немає `export $(grep ...)`, тож покладатися
    # на ручний експорт змінних не можна.
    from .envfile import load_env_file
    load_env_file()

    if args.list_devices:
        from .audio_io import list_devices
        print(list_devices())
        return 0

    overrides = {
        "wake.mode": args.wake,
        "character.voice": args.voice,
        "gemini.model": args.model,
        "logging.level": args.log_level,
    }
    overrides = {k: v for k, v in overrides.items() if v is not None}

    try:
        cfg = load_config(args.config, args.character, overrides=overrides)
    except ConfigError as exc:
        print(f"❌ Помилка конфігурації: {exc}", file=sys.stderr)
        return 2

    _setup_logging(cfg.logging)

    # Імпортуємо тут, щоб --list-devices/--help працювали без важких залежностей.
    from .orchestrator import Orchestrator

    try:
        orch = Orchestrator(cfg)
    except Exception as exc:  # noqa: BLE001
        print(f"❌ Не вдалося ініціалізувати агента: {exc}", file=sys.stderr)
        return 1

    try:
        if args.calibrate:
            asyncio.run(orch.calibrate())
        else:
            asyncio.run(orch.run_forever(once=args.once))
    except KeyboardInterrupt:
        print("\n👋 Зупинено користувачем.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Згенерувати локальне голосове оголошення для перезапуску квесту:
    mobile/assets/audio/restart_notice.mp3

Текст — той самий, що в mobile/lib/quest/restart_notice.dart
(RestartNotice.text). Синтез — gTTS (Google Translate TTS, українська),
потрібен інтернет:

    pip install gTTS
    python scripts/make_restart_notice.py

Файл далі потрапляє в APK; без нього застосунок озвучує текст системним
синтезатором Android (якщо є український голос).
"""

from __future__ import annotations

import sys
from pathlib import Path

TEXT = (
    "УВАГА! Інтерактивного персонажа перезапущено. "
    "Щоб розпочати новий квест — промовте кодове слово."
)
OUT = Path(__file__).resolve().parent.parent / "mobile" / "assets" / "audio" / "restart_notice.mp3"


def main() -> int:
    try:
        from gtts import gTTS
    except ImportError:
        print("Потрібен пакет gTTS:  pip install gTTS", file=sys.stderr)
        return 1
    OUT.parent.mkdir(parents=True, exist_ok=True)
    gTTS(text=TEXT, lang="uk", slow=False).save(str(OUT))
    print(f"✅ {OUT} ({OUT.stat().st_size} байт)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

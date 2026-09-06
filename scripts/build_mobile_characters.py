#!/usr/bin/env python3
"""Зібрати мобільні копії персонажів: characters/*.yaml → mobile/assets/characters/*.json

Мобільний застосунок не читає YAML і не знає структури сценарію
(persona/questions/…): він тримає по одному JSON на персонажа з уже
ЗІБРАНОЮ системною інструкцією. Ці JSON — «типові персонажі з комплекту»:
CharacterStore.ensureDefaults копіює їх на телефон при першому запуску (лише
ті, яких ще немає на диску, щоб не затерти правки користувача).

Тож після КОЖНОЇ правки characters/*.yaml (або domovyk_quest/prompt.py)
треба перегенерувати JSON цим скриптом і закомітити результат.

Рецепт: повний build_system_instruction() з вирізаними мовним і акторським
блоками — їх мобільний бік додає сам (constants.dart::kLanguageRules /
kPerformanceRules), щоб правки цих блоків не вимагали перегенерації.

    python scripts/build_mobile_characters.py            # усі персонажі
    python scripts/build_mobile_characters.py derevo     # лише вказані id

Читає ЯВНО файловий бекенд (characters/*.yaml) незалежно від storage.backend
у config.yaml — джерело істини для комплекту завжди в репозиторії.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from domovyk_quest import characters as fs  # noqa: E402
from domovyk_quest.prompt import (  # noqa: E402
    LANGUAGE_RULES,
    PERFORMANCE_RULES,
    build_system_instruction,
)

OUT_DIR = ROOT / "mobile" / "assets" / "characters"


def build_one(char_id: str) -> dict:
    raw = fs.read_raw(char_id)
    ch = fs.build_character(raw)
    full = build_system_instruction(ch)
    stripped = full.replace(LANGUAGE_RULES, "").replace(PERFORMANCE_RULES, "")
    return {
        "id": ch.id,
        "display_name": ch.display_name,
        "provider": "google",  # мобільний застосунок працює через Gemini Live
        "openai_voice": ch.openai_voice or "marin",
        "voice": ch.voice,
        "speech_speed": ch.speech_speed or 1.0,
        "system_prompt": stripped,
        "win_word": ch.win_word,
        "wake_words": list(ch.wake_words),
        "stop_words": list(ch.stop_words),
        "wake_on_voice": bool(ch.wake_on_voice),
        "inactivity_timeout_s": ch.inactivity_timeout_s,
        "answer_wait_s": ch.answer_wait_s,
        "context_compression": bool(ch.context_compression),
    }


def main(argv: list[str]) -> int:
    ids = argv or sorted(p.stem for p in fs.characters_dir().glob("*.yaml"))
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for cid in ids:
        doc = build_one(cid)
        path = OUT_DIR / f"{cid}.json"
        with path.open("w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        print(f"{cid:12s} voice={doc['voice']:12s} win={doc['win_word'] or '—':14s} "
              f"stop={','.join(doc['stop_words']) or '—':10s} "
              f"voice-wake={'yes' if doc['wake_on_voice'] else 'no':3s} "
              f"idle={doc['inactivity_timeout_s'] or 'default'} "
              f"wait={doc['answer_wait_s']} "
              f"compress={'yes' if doc['context_compression'] else 'no':3s} "
              f"→ {path.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

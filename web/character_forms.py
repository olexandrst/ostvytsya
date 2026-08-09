"""Спільна логіка форми персонажа: збирання YAML-словника з полів форми
(display_name, provider, голоси, промпт, кодові слова, фінальне слово) та
рішення, чи власний промпт зберігати, чи лишити персонажа жити YAML-сценарієм.
Винесено з web/app.py окремо, щоб маршрути створення й редагування (які
роблять цю збірку двічі) не розходилися в деталях.
"""

from __future__ import annotations

from typing import Any, Optional

from domovyk_quest.characters_store import PROVIDERS, build_character
from domovyk_quest.prompt import build_system_instruction


def payload_from_form(form: dict[str, Any], base: Optional[dict[str, Any]] = None
                      ) -> dict[str, Any]:
    """Скласти YAML-словник персонажа, зберігши поля, яких немає у формі.

    Це важливо: у формі редагуються лише назва/голос/промпт, а persona, style,
    questions, directives тощо мають лишитися недоторканими.
    """
    data = dict(base or {})
    data["display_name"] = (form.get("display_name") or "").strip()
    provider = (form.get("provider") or data.get("provider") or "openai").strip()
    data["provider"] = provider if provider in PROVIDERS else "openai"
    data["openai_voice"] = (form.get("openai_voice") or "marin").strip()
    data["voice"] = (form.get("voice") or data.get("voice") or "Charon").strip()
    data["system_prompt"] = (form.get("system_prompt") or "").strip()
    try:
        data["speech_speed"] = round(float(form.get("speech_speed") or 1.0), 2)
    except (TypeError, ValueError):
        data["speech_speed"] = 1.0

    words_raw = form.get("wake_words")
    if isinstance(words_raw, list):
        words = [str(w).strip() for w in words_raw if str(w).strip()]
    else:
        words = [w.strip() for w in (words_raw or "").split(",") if w.strip()]
    if words:
        data["wake_words"] = words
    elif not data.get("wake_words"):
        # Консольний режим вимагає кодового слова — тож даємо розумний типовий.
        data["wake_words"] = [data["display_name"]] if data["display_name"] else ["Оствиця"]

    win = (form.get("win_word") or "").strip()
    if win:
        data["win_word"] = win
    elif not data.get("win_word"):
        data["win_word"] = "Перемога"

    data.setdefault("language", "uk-UA")
    data.setdefault("persona", "")
    data.setdefault("style", [])
    data.setdefault("intro", "")
    data.setdefault("win", "")
    # Порожній власний промпт у файлі не тримаємо: його відсутність і означає
    # «персонаж живе своїм YAML-сценарієм».
    if not data.get("system_prompt"):
        data.pop("system_prompt", None)
    return data


def resolve_system_prompt(payload: dict[str, Any], base: dict[str, Any]) -> dict[str, Any]:
    """Якщо надісланий промпт дослівно збігається зі зібраним зі сценарію —
    не «фіксувати» його в system_prompt, щоб персонаж і далі жив YAML-сценарієм
    (правки сценарію тоді одразу відображаються в грі, без ручного повторного
    редагування промпту)."""
    submitted = (payload.get("system_prompt") or "").strip()
    if submitted and base.get("questions"):
        scenario_prompt = build_system_instruction(
            build_character({**base, "system_prompt": ""})
        ).strip()
        if submitted == scenario_prompt:
            payload.pop("system_prompt", None)
    return payload

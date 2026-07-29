"""Інтеграція з OpenAI Realtime API (gpt-realtime-2.1).

Браузер НІКОЛИ не бачить справжнього ключа OpenAI. Схема така:
  1. сервер (цей модуль) робить POST /v1/realtime/client_secrets і отримує
     короткоживучий ephemeral-токен разом із конфігурацією сесії;
  2. браузер із цим токеном сам піднімає WebRTC-з'єднання просто до OpenAI
     (POST /v1/realtime/calls) — звук іде напряму, без проксі через наш сервер.

Персонаж (його системна інструкція та голос) задається на боці сервера, тож
клієнт не може підмінити ані промпт, ані модель.
"""

from __future__ import annotations

import os
from typing import Any

import httpx

from domovyk_quest.characters import OPENAI_VOICES
from domovyk_quest.config import Character
from domovyk_quest.prompt import build_system_instruction

CLIENT_SECRETS_URL = "https://api.openai.com/v1/realtime/client_secrets"
DEFAULT_MODEL = "gpt-realtime-2.1"
# Скільки живе ephemeral-токен. Його вистачає лише на встановлення з'єднання —
# сама розмова після цього триває стільки, скільки треба.
TOKEN_TTL_S = 600

# Службовий сигнал, яким веб-режим просить персонажа заговорити першим.
#
# УВАГА: цей текст надсилається як ПОВІДОМЛЕННЯ КОРИСТУВАЧА, а не як
# response.instructions. У Realtime API поле instructions у response.create
# ЗАМІНЮЄ системні інструкції для цієї відповіді — тобто персонаж згенерував би
# перше вітання, не бачачи власного сценарію, і почав би імпровізувати.
GREETING_TRIGGER = (
    "[Службовий сигнал — не читай його вголос і не згадуй про нього. Діти щойно "
    "промовили твоє чарівне кодове слово і мовчки стоять перед тобою, чекаючи. "
    "Квест починається ПРЯМО ЗАРАЗ. Негайно заговори САМ: привітайся строго за "
    "своїм сценарієм, у повному образі, живо й емоційно, і одразу переходь до "
    "першого кроку квесту. Не чекай, поки діти заговорять, не питай дозволу і не "
    "вигадуй власних завдань — веди рівно той квест, що описаний у твоїх "
    "інструкціях.]"
)


class RealtimeError(Exception):
    """Помилка створення сесії OpenAI Realtime."""


def api_key() -> str:
    key = (os.environ.get("OPENAI_API_KEY") or "").strip()
    if not key:
        raise RealtimeError(
            "Не задано OPENAI_API_KEY. Додай ключ у .env — його можна взяти "
            "на https://platform.openai.com/api-keys"
        )
    return key


def model_name() -> str:
    return (os.environ.get("OPENAI_REALTIME_MODEL") or DEFAULT_MODEL).strip()


def build_session_config(character: Character) -> dict[str, Any]:
    """Конфігурація Realtime-сесії для конкретного персонажа."""
    voice = (character.openai_voice or "marin").strip()
    if voice not in OPENAI_VOICES:
        voice = "marin"
    try:
        speed = float(character.speech_speed or 1.0)
    except (TypeError, ValueError):
        speed = 1.0
    speed = min(max(speed, 0.25), 2.0)

    return {
        "type": "realtime",
        "model": model_name(),
        "instructions": build_system_instruction(character),
        "audio": {
            "input": {
                # Транскрипція мовлення дитини — щоб показувати діалог у вебі.
                "transcription": {"model": "gpt-realtime-whisper", "language": "uk"},
                "turn_detection": {
                    "type": "server_vad",
                    # Персонажа не можна перебити: поки він говорить, будь-який
                    # звук у мікрофоні не уриває його репліку. create_response
                    # лишаємо true, щоб він відповідав, коли дитина договорила.
                    "interrupt_response": False,
                    "create_response": True,
                    # Трохи довша пауза: діти говорять із запинками, і не варто
                    # вважати кожну паузу кінцем відповіді.
                    "silence_duration_ms": 700,
                },
            },
            "output": {"voice": voice, "speed": speed},
        },
    }


async def create_client_secret(character: Character) -> dict[str, Any]:
    """Отримати ephemeral-токен для браузера."""
    payload = {
        "expires_after": {"anchor": "created_at", "seconds": TOKEN_TTL_S},
        "session": build_session_config(character),
    }
    headers = {
        "Authorization": f"Bearer {api_key()}",
        "Content-Type": "application/json",
    }
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(CLIENT_SECRETS_URL, json=payload, headers=headers)
    except httpx.HTTPError as exc:
        raise RealtimeError(f"Не вдалося звернутися до OpenAI: {exc}") from exc

    if resp.status_code >= 400:
        detail = resp.text[:400]
        raise RealtimeError(f"OpenAI відповів {resp.status_code}: {detail}")

    data = resp.json()
    # У відповіді ключ називається «value»; підстраховуємось на випадок,
    # якщо API поверне його вкладеним.
    secret = data.get("value") or (data.get("client_secret") or {}).get("value")
    if not secret:
        raise RealtimeError("OpenAI не повернув ephemeral-токен.")
    return {
        "client_secret": secret,
        "expires_at": data.get("expires_at"),
        "model": model_name(),
    }

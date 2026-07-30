"""Міст «браузер ⇄ Gemini Live» для веб-квесту з провайдером google.

OpenAI Realtime браузер тягне сам через WebRTC, а Gemini Live працює по
WebSocket із сирим PCM — тож для нього тримаємо міст на сервері:

    браузер ──WebSocket──▶ цей модуль ──google-genai──▶ Gemini Live
            ◀── аудіо + транскрипти ───┘

Такий міст має дві переваги: ключ Gemini не потрапляє в браузер, і формат
сесії (персона, голос, транскрипція) задає сервер — так само, як для OpenAI.

Формат обміну з браузером:
  * бінарні кадри   — сирий PCM16: від браузера 16 кГц, до браузера 24 кГц;
  * текстові кадри  — JSON із подіями (транскрипти, статуси, помилки).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import Any, Optional

from domovyk_quest.config import Character
from domovyk_quest.characters import GEMINI_VOICES
from domovyk_quest.prompt import build_system_instruction

log = logging.getLogger("ostvytsya.web.gemini")

DEFAULT_MODEL = "gemini-2.5-flash-native-audio-preview-09-2025"
API_VERSION = "v1beta"

# Той самий службовий сигнал, що й для OpenAI: квест має початися сам.
GREETING_TRIGGER = (
    "[Службовий сигнал — не читай його вголос і не згадуй про нього. Діти щойно "
    "промовили твоє чарівне кодове слово і мовчки стоять перед тобою, чекаючи. "
    "Квест починається ПРЯМО ЗАРАЗ. Негайно заговори САМ: привітайся строго за "
    "своїм сценарієм, у повному образі, живо й емоційно, і одразу переходь до "
    "першого кроку квесту. Не чекай, поки діти заговорять, і не вигадуй власних "
    "завдань — веди рівно той квест, що описаний у твоїх інструкціях.]"
)


class GeminiLiveError(Exception):
    """Помилка налаштування або з'єднання з Gemini Live."""


def _genai():
    """Підвантажити google-genai на вимогу.

    Пакет потрібен лише персонажам із провайдером google, тож імпортуємо його
    в момент використання — інакше відсутній (чи поламаний) google-genai клав
    би весь веб-додаток, включно з OpenAI-персонажами.
    """
    try:
        from google import genai
        from google.genai import types
    except Exception as exc:  # noqa: BLE001 — трапляються й не-ImportError
        raise GeminiLiveError(
            "Не вдалося підвантажити google-genai — він потрібен для персонажів "
            f"із моделлю Google Gemini. Встанови: pip install google-genai ({exc})"
        ) from exc
    return genai, types


def api_key() -> str:
    key = (os.environ.get("GEMINI_API_KEY") or "").strip()
    if not key:
        raise GeminiLiveError(
            "Не задано GEMINI_API_KEY. Додай ключ у .env — його можна взяти "
            "на https://aistudio.google.com/apikey"
        )
    return key


def model_name() -> str:
    return (os.environ.get("GEMINI_LIVE_MODEL") or DEFAULT_MODEL).strip()


def build_live_config(character: Character):
    _, types = _genai()
    voice = (character.voice or "Charon").strip()
    if voice not in GEMINI_VOICES:
        voice = "Charon"
    return types.LiveConnectConfig(
        response_modalities=["AUDIO"],
        speech_config=types.SpeechConfig(
            voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=voice)
            ),
        ),
        system_instruction=types.Content(
            parts=[types.Part(text=build_system_instruction(character))]
        ),
        input_audio_transcription=types.AudioTranscriptionConfig(),
        output_audio_transcription=types.AudioTranscriptionConfig(),
        context_window_compression=types.ContextWindowCompressionConfig(
            sliding_window=types.SlidingWindow()
        ),
    )


def _audio_from_response(response) -> bytes:
    """Витягти лише аудіо з відповіді (ігноруючи текст і 'thought'-частини)."""
    sc = getattr(response, "server_content", None)
    if sc is None:
        return b""
    mt = getattr(sc, "model_turn", None)
    if mt is None or not getattr(mt, "parts", None):
        return b""
    chunks = []
    for part in mt.parts:
        inline = getattr(part, "inline_data", None)
        if inline is not None and getattr(inline, "data", None):
            chunks.append(inline.data)
    return b"".join(chunks)


class QuestBridge:
    """Одна сесія квесту: браузер ⇄ Gemini Live."""

    def __init__(self, websocket, character: Character) -> None:
        self.ws = websocket
        self.character = character
        self.session = None
        self._closed = asyncio.Event()

    async def send_event(self, **payload: Any) -> None:
        try:
            await self.ws.send_text(json.dumps(payload, ensure_ascii=False))
        except Exception:  # noqa: BLE001 — браузер міг відключитися
            self._closed.set()

    async def run(self) -> None:
        genai, types = _genai()
        client = genai.Client(
            api_key=api_key(),
            http_options=types.HttpOptions(api_version=API_VERSION),
        )
        model = model_name()
        log.info("Gemini Live: відкриваю сесію «%s» (голос %s, модель %s)",
                 self.character.display_name, self.character.voice, model)

        async with client.aio.live.connect(
            model=model, config=build_live_config(self.character)
        ) as session:
            self.session = session
            await self.send_event(type="ready", voice=self.character.voice, model=model)

            # Квест стартує сам — так, ніби кодове слово вже прозвучало.
            await session.send_client_content(
                turns=types.Content(role="user",
                                    parts=[types.Part(text=GREETING_TRIGGER)]),
                turn_complete=True,
            )

            tasks = [
                asyncio.create_task(self._pump_browser_to_gemini()),
                asyncio.create_task(self._pump_gemini_to_browser()),
            ]
            try:
                await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            finally:
                for t in tasks:
                    t.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)

    async def _pump_browser_to_gemini(self) -> None:
        """Мікрофон дитини → модель."""
        _, types = _genai()
        rate = 16000
        mime = f"audio/pcm;rate={rate}"
        try:
            while not self._closed.is_set():
                message = await self.ws.receive()
                if message.get("type") == "websocket.disconnect":
                    break
                data = message.get("bytes")
                if data:
                    await self.session.send_realtime_input(
                        audio=types.Blob(data=data, mime_type=mime)
                    )
                    continue
                text = message.get("text")
                if text:
                    try:
                        evt = json.loads(text)
                    except ValueError:
                        continue
                    if evt.get("type") == "stop":
                        break
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            log.debug("browser→gemini: %s", exc)
        finally:
            self._closed.set()

    async def _pump_gemini_to_browser(self) -> None:
        """Голос персонажа й транскрипти → браузер."""
        name = self.character.display_name
        try:
            while not self._closed.is_set():
                got = False
                async for response in self.session.receive():
                    got = True
                    audio = _audio_from_response(response)
                    if audio:
                        try:
                            await self.ws.send_bytes(audio)
                        except Exception:  # noqa: BLE001
                            self._closed.set()
                            return

                    sc = getattr(response, "server_content", None)
                    if sc is None:
                        continue

                    it = getattr(sc, "input_transcription", None)
                    if it is not None and getattr(it, "text", None):
                        await self.send_event(type="user_text", text=it.text)

                    ot = getattr(sc, "output_transcription", None)
                    if ot is not None and getattr(ot, "text", None):
                        await self.send_event(type="agent_text", text=ot.text, who=name)

                    if getattr(sc, "turn_complete", False):
                        await self.send_event(type="turn_complete")

                if not got:
                    break
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            log.warning("gemini→browser: %s", exc)
            await self.send_event(type="error", message=str(exc))
        finally:
            self._closed.set()


async def run_quest(websocket, character: Character) -> None:
    """Провести один веб-квест через Gemini Live."""
    bridge = QuestBridge(websocket, character)
    try:
        await bridge.run()
    except GeminiLiveError as exc:
        await bridge.send_event(type="error", message=str(exc))
    except asyncio.CancelledError:
        raise
    except Exception as exc:  # noqa: BLE001
        log.error("Gemini Live: %s", exc)
        await bridge.send_event(type="error", message=f"Помилка Gemini: {exc}")

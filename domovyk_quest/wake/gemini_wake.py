"""Детектор кодового слова через Gemini Live (native audio).

Відкриває Live-сесію, стрімить мікрофон і чекає, доки в транскрипції ВХОДУ
не з'явиться кодове слово. Модель просять мовчати, а її аудіо-вихід ми НЕ
відтворюємо — тож лялька лишається тихою. На відміну від офлайн-Vosk, надійно
розпізнає власні назви (напр. «Оствиця») будь-якою мовою.

ВАЖЛИВО: native-audio моделі підтримують лише модальність AUDIO (модальність
TEXT сервер відхиляє), тому ми слухаємо з AUDIO, а вихідне аудіо ігноруємо.

УВАГА: постійно стрімить аудіо в хмару, поки чекає, тож для цілодобової
інсталяції він дорожчий за локальний vosk. Зручний, коли vosk недоступний.
"""

from __future__ import annotations

import asyncio
import logging
import unicodedata

from google.genai import types

from ..audio_io import AudioIO, rms
from .base import WakeGate

log = logging.getLogger("ostvytsya.wake.gemini")

_SILENT_SYSTEM = (
    "Ти — мовчазний вартовий. Мовчи й нічого не кажи вголос. Лише слухай. "
    "Хай там що почуєш — не відповідай."
)


def _norm(s: str) -> str:
    return unicodedata.normalize("NFKC", s or "").lower()


class GeminiWakeGate(WakeGate):
    def __init__(self, client, cfg) -> None:
        self.client = client
        self.cfg = cfg
        self._words = [_norm(w) for w in cfg.character.wake_words if w.strip()]

    def _config(self) -> types.LiveConnectConfig:
        # Native-audio модель підтримує лише AUDIO. Вихідне аудіо не відтворюємо.
        return types.LiveConnectConfig(
            response_modalities=["AUDIO"],
            system_instruction=types.Content(parts=[types.Part(text=_SILENT_SYSTEM)]),
            input_audio_transcription=types.AudioTranscriptionConfig(),
        )

    def _matches(self, text: str) -> bool:
        t = _norm(text)
        return any(w in t for w in self._words)

    async def wait_for_wake(self, audio: AudioIO) -> bool:
        audio.drain_mic()
        log.info("💤 Сплю (через Gemini). Чекаю кодове слово…")
        found = asyncio.Event()

        async with self.client.aio.live.connect(
            model=self.cfg.gemini.model, config=self._config()
        ) as session:

            async def sender():
                rate = self.cfg.audio.input_sample_rate
                floor = self.cfg.audio.vad_rms_threshold * 0.4
                mime = f"audio/pcm;rate={rate}"
                while not found.is_set():
                    data = await audio.read()
                    if rms(data) < floor:  # не женемо суцільну тишу в хмару
                        continue
                    try:
                        await session.send_realtime_input(
                            audio=types.Blob(data=data, mime_type=mime)
                        )
                    except Exception:  # noqa: BLE001
                        break

            async def receiver():
                buf = ""
                while not found.is_set():
                    got = False
                    async for response in session.receive():
                        got = True
                        # Аудіо-вихід моделі свідомо НЕ відтворюємо (тиша).
                        sc = getattr(response, "server_content", None)
                        if sc is None:
                            continue
                        it = getattr(sc, "input_transcription", None)
                        if it is not None and getattr(it, "text", None):
                            buf += it.text
                            log.debug("чую (gemini): %s", buf.strip())
                            if self._matches(buf):
                                log.info("🔑 Почуто кодове слово.")
                                found.set()
                                return
                        if getattr(sc, "turn_complete", False):
                            buf = ""
                    if not got:  # з'єднання закрите — не крутимося марно
                        break

            send_task = asyncio.create_task(sender())
            recv_task = asyncio.create_task(receiver())
            try:
                await found.wait()
            finally:
                for t in (send_task, recv_task):
                    t.cancel()
                await asyncio.gather(send_task, recv_task, return_exceptions=True)
        return True

    async def calibrate(self, audio: AudioIO) -> None:
        log.info("🎚️  КАЛІБРУВАННЯ (Gemini). Промовляй кодове слово — покажу, "
                 "як я його чую. Ctrl+C — вихід.")
        async with self.client.aio.live.connect(
            model=self.cfg.gemini.model, config=self._config()
        ) as session:
            rate = self.cfg.audio.input_sample_rate
            floor = self.cfg.audio.vad_rms_threshold * 0.4
            mime = f"audio/pcm;rate={rate}"

            async def sender():
                while True:
                    data = await audio.read()
                    if rms(data) < floor:
                        continue
                    try:
                        await session.send_realtime_input(
                            audio=types.Blob(data=data, mime_type=mime)
                        )
                    except Exception:  # noqa: BLE001
                        break

            task = asyncio.create_task(sender())
            try:
                buf = ""
                while True:
                    async for response in session.receive():
                        sc = getattr(response, "server_content", None)
                        if sc is None:
                            continue
                        it = getattr(sc, "input_transcription", None)
                        if it is not None and getattr(it, "text", None):
                            buf += it.text
                            hit = "  ✅ ЗБІГ" if self._matches(buf) else ""
                            log.info("    · чую: «%s»%s", buf.strip(), hit)
                        if getattr(sc, "turn_complete", False):
                            buf = ""
            finally:
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)

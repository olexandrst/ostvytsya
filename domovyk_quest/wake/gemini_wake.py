"""Детектор кодового слова через Gemini Live (без зайвих залежностей).

Відкриває легку Live-сесію лише з транскрипцією входу (модель просять мовчати),
стрімить мікрофон і чекає, доки в розшифровці входу не з'явиться кодове слово.
Жодного звуку від ляльки в цьому режимі немає.

УВАГА: цей режим постійно стрімить аудіо в хмару, поки чекає, тож для постійно
ввімкненої інсталяції він дорожчий за локальний vosk. Зручний для демо/розробки.
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
    "Ти — мовчазний вартовий. Не відповідай і не видавай жодного тексту. "
    "Просто слухай. Якщо тебе щось запитають — мовчи."
)


def _norm(s: str) -> str:
    return unicodedata.normalize("NFKC", s or "").lower()


class GeminiWakeGate(WakeGate):
    def __init__(self, client, cfg) -> None:
        self.client = client
        self.cfg = cfg
        self._words = [_norm(w) for w in cfg.character.wake_words if w.strip()]

    def _config(self) -> types.LiveConnectConfig:
        return types.LiveConnectConfig(
            response_modalities=["TEXT"],
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
                thr = self.cfg.audio.vad_rms_threshold
                mime = f"audio/pcm;rate={rate}"
                while not found.is_set():
                    data = await audio.read()
                    # Не женемо в хмару суцільну тишу — економимо трафік/гроші.
                    if rms(data) < thr * 0.6:
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
                    async for response in session.receive():
                        sc = getattr(response, "server_content", None)
                        if sc is None:
                            continue
                        it = getattr(sc, "input_transcription", None)
                        if it is not None and getattr(it, "text", None):
                            buf += it.text
                            if self._matches(buf):
                                log.info("🔑 Почуто кодове слово.")
                                found.set()
                                return
                        if getattr(sc, "turn_complete", False):
                            buf = ""

            send_task = asyncio.create_task(sender())
            recv_task = asyncio.create_task(receiver())
            try:
                await found.wait()
            finally:
                for t in (send_task, recv_task):
                    t.cancel()
                await asyncio.gather(send_task, recv_task, return_exceptions=True)
        return True

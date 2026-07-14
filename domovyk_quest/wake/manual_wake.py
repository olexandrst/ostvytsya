"""Ручний «детектор» кодового слова: натискання Enter.

Для розробки й тестів без мікрофона/моделі розпізнавання.
"""

from __future__ import annotations

import asyncio
import logging

from ..audio_io import AudioIO
from .base import WakeGate

log = logging.getLogger("ostvytsya.wake.manual")


class ManualWakeGate(WakeGate):
    def __init__(self, cfg) -> None:
        self._prompt = (
            f"\n💤 [ручний режим] Натисни Enter, щоб «промовити» «"
            f"{cfg.character.wake_words[0]}» і почати квест (Ctrl+C — вихід)… "
        )

    async def wait_for_wake(self, audio: AudioIO) -> bool:
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, input, self._prompt)
        log.info("🔑 Кодове слово «промовлено» вручну.")
        return True

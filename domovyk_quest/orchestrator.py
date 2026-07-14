"""Головний цикл агента: спокій → пробудження → квест → скидання → знову спокій."""

from __future__ import annotations

import asyncio
import logging

from google import genai
from google.genai import types

from .audio_io import AudioIO
from .config import AppConfig
from .session import Outcome, QuestSession
from .wake import create_wake_gate

log = logging.getLogger("ostvytsya")


class Orchestrator:
    def __init__(self, cfg: AppConfig) -> None:
        self.cfg = cfg
        self.client = genai.Client(
            api_key=cfg.api_key,
            http_options=types.HttpOptions(api_version=cfg.gemini.api_version),
        )
        self.audio = AudioIO(cfg.audio)
        self.wake = create_wake_gate(cfg, self.client)
        self.quest = QuestSession(self.client, cfg, self.audio)

    async def run_forever(self, once: bool = False) -> None:
        await self.audio.start()
        ch = self.cfg.character
        log.info("🌳 Персонаж «%s» на дереві. Кодове слово: «%s». Режим спокою: %s.",
                 ch.display_name, ch.wake_words[0], self.cfg.wake.mode)
        try:
            while True:
                woke = await self.wake.wait_for_wake(self.audio)
                if not woke:
                    break

                log.info("✨ Пробудження. Починаю квест…")
                outcome = await self.quest.run()
                self._report(outcome)

                if once:
                    break
                await asyncio.sleep(self.cfg.session.cooldown_s)
        finally:
            await self.wake.close()
            await self.audio.close()
            log.info("Агента зупинено.")

    async def calibrate(self) -> None:
        """Діагностика розпізнавання кодового слова (див. --calibrate)."""
        await self.audio.start()
        try:
            await self.wake.calibrate(self.audio)
        finally:
            await self.wake.close()
            await self.audio.close()

    def _report(self, outcome: Outcome) -> None:
        if outcome is Outcome.WON:
            log.info("🏆 Квест пройдено! Слово «%s» назване.", self.cfg.character.win_word)
        elif outcome is Outcome.TIMEOUT:
            log.info("🕊️  Квест завершено за тайм-аутом. Засинаю.")
        elif outcome is Outcome.ERROR:
            log.warning("⚠️  Квест завершився з помилкою. Засинаю.")
        else:
            log.info("Квест зупинено.")

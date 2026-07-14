"""Сесія квесту на Gemini Live API (Native Audio).

Веде живу голосову розмову: стрімить мікрофон у модель, відтворює відповідь
голосом персонажа, відстежує транскрипти, ловить «перебивання» (barge-in),
завершує квест, коли модель промовила таємне слово, та засинає за тайм-аутом
бездіяльності.
"""

from __future__ import annotations

import asyncio
import enum
import logging
import time
import unicodedata
from dataclasses import dataclass, field
from typing import Optional

from google.genai import types

from .audio_io import AudioIO, rms
from .config import AppConfig
from .prompt import GREETING_TRIGGER, build_system_instruction

log = logging.getLogger("ostvytsya.session")


class Outcome(enum.Enum):
    WON = "won"            # квест пройдено, таємне слово назване
    TIMEOUT = "timeout"    # гравець замовк / вичерпано час
    ERROR = "error"        # помилка з'єднання тощо
    ABORTED = "aborted"    # зовнішня зупинка


def _normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text or "").lower()
    return "".join(ch if ch.isalnum() or ch.isspace() else " " for ch in text)


def _audio_from_response(response) -> bytes:
    """Зібрати лише аудіо з частин відповіді (ігноруючи text/thought).

    Замінює response.data, який сипле попередженням 'non-data parts', коли
    модель повертає ще й текст чи 'thought'-частини.
    """
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


@dataclass
class _State:
    last_user_voice: float = field(default_factory=time.monotonic)
    user_buf: str = ""
    model_buf: str = ""
    won: bool = False
    outcome: Optional[Outcome] = None
    # Напівдуплекс: чи агент зараз говорить, і коли він востаннє був активний.
    agent_speaking: bool = True
    speaking_ended_at: float = 0.0
    got_audio: bool = False  # чи модель уже щось сказала (для страхування вітання)


class QuestSession:
    def __init__(self, client, cfg: AppConfig, audio: AudioIO) -> None:
        self.client = client
        self.cfg = cfg
        self.audio = audio
        self.character = cfg.character
        # Стем таємного слова, щоб ловити будь-який відмінок ("Лабуда"/"Лабуду").
        w = _normalize(self.character.win_word).strip()
        self._win_stem = w[:-1] if len(w) > 4 else w

    def _live_config(self) -> types.LiveConnectConfig:
        sys_text = build_system_instruction(self.character)
        return types.LiveConnectConfig(
            response_modalities=["AUDIO"],
            speech_config=types.SpeechConfig(
                voice_config=types.VoiceConfig(
                    prebuilt_voice_config=types.PrebuiltVoiceConfig(
                        voice_name=self.character.voice
                    )
                ),
            ),
            system_instruction=types.Content(parts=[types.Part(text=sys_text)]),
            input_audio_transcription=types.AudioTranscriptionConfig(),
            output_audio_transcription=types.AudioTranscriptionConfig(),
        )

    async def run(self) -> Outcome:
        """Провести один квест від пробудження до завершення."""
        self.audio.drain_mic()
        try:
            async with self.client.aio.live.connect(
                model=self.cfg.gemini.model, config=self._live_config()
            ) as session:
                log.info("Сесію Gemini Live відкрито (голос: %s)", self.character.voice)
                state = _State()
                end = asyncio.Event()

                # Персонаж має заговорити ПЕРШИМ, щойно дитина сказала кодове слово.
                if self.cfg.session.greeting_on_wake:
                    await self._send_greeting(session)

                tasks = [
                    asyncio.create_task(self._send_loop(session, state, end)),
                    asyncio.create_task(self._recv_loop(session, state, end)),
                    asyncio.create_task(self._watchdog(state, end)),
                ]
                if self.cfg.session.greeting_on_wake:
                    tasks.append(
                        asyncio.create_task(self._greeting_nudge(session, state, end))
                    )
                try:
                    await asyncio.wait_for(
                        end.wait(), timeout=self.cfg.session.max_duration_s
                    )
                except asyncio.TimeoutError:
                    log.info("Досягнуто ліміт тривалості квесту.")
                    if state.outcome is None:
                        state.outcome = Outcome.TIMEOUT
                finally:
                    for t in tasks:
                        t.cancel()
                    await asyncio.gather(*tasks, return_exceptions=True)
                    self.audio.stop_playback()
                return state.outcome or Outcome.TIMEOUT
        except asyncio.CancelledError:
            return Outcome.ABORTED
        except Exception as exc:  # noqa: BLE001
            log.error("Помилка сесії Gemini Live: %s", exc)
            return Outcome.ERROR

    # ── проактивне вітання ───────────────────────────────────────────────────

    async def _send_greeting(self, session) -> None:
        # send_client_content лише «підсаджує» історію в чергу й не гарантує
        # швидкої відповіді (за офіційною документацією Live API — використовується
        # для попереднього наповнення контексту, а не як реальний тригер мовлення).
        # send_realtime_input трактує вхід як живу активність користувача (як мову)
        # і надійно змушує native-audio модель відповісти голосом одразу.
        await session.send_realtime_input(text=GREETING_TRIGGER)

    async def _greeting_nudge(self, session, state: _State, end: asyncio.Event) -> None:
        """Страховка: якщо персонаж не заговорив сам — повторно спонукаємо його.

        Іноді native-audio модель «проспинає» перший текстовий сигнал і чекає
        на голос дитини. Щоб персонаж гарантовано почав розмову першим, за
        кілька секунд тиші повторюємо сигнал (кілька разів).
        """
        for _ in range(3):
            try:
                await asyncio.sleep(self.cfg.session.greeting_nudge_s)
            except asyncio.CancelledError:
                raise
            if end.is_set() or state.got_audio:
                return
            log.info("Персонаж іще мовчить — повторно спонукаю привітатися…")
            try:
                await self._send_greeting(session)
            except Exception as exc:  # noqa: BLE001
                log.debug("greeting nudge: %s", exc)
                return

    # ── мікрофон → модель ────────────────────────────────────────────────────

    async def _send_loop(self, session, state: _State, end: asyncio.Event) -> None:
        rate = self.cfg.audio.input_sample_rate
        threshold = self.cfg.audio.vad_rms_threshold
        mime = f"audio/pcm;rate={rate}"
        half_duplex = self.cfg.session.half_duplex
        guard_s = self.cfg.session.echo_guard_ms / 1000.0
        was_blocking = False
        while not end.is_set():
            data = await self.audio.read()

            # Напівдуплекс: поки агент говорить (або щойно договорив), НЕ шлемо
            # мікрофон у модель — інакше вона чує власне відлуння з колонки,
            # серверний VAD приймає це за перебивання і модель уривається.
            if half_duplex:
                speaking = state.agent_speaking or not self.audio.output_idle
                if speaking:
                    state.speaking_ended_at = time.monotonic()
                    was_blocking = True
                    continue
                if time.monotonic() - state.speaking_ended_at < guard_s:
                    was_blocking = True
                    continue
                if was_blocking:
                    # Мікрофон щойно «відкрився» — викидаємо рештки відлуння.
                    self.audio.drain_mic()
                    was_blocking = False
                    continue

            if rms(data) >= threshold:
                state.last_user_voice = time.monotonic()
            try:
                await session.send_realtime_input(
                    audio=types.Blob(data=data, mime_type=mime)
                )
            except Exception as exc:  # noqa: BLE001
                log.debug("send_realtime_input: %s", exc)
                break

    # ── модель → колонка ─────────────────────────────────────────────────────

    async def _recv_loop(self, session, state: _State, end: asyncio.Event) -> None:
        transcript = self.cfg.logging.transcript
        try:
            while not end.is_set():
                # session.receive() віддає один хід і завершується на turn_complete,
                # тож зовнішній цикл потрібен для наступних ходів.
                got_message = False
                async for response in session.receive():
                    got_message = True
                    audio_bytes = _audio_from_response(response)
                    if audio_bytes:
                        self.audio.play(audio_bytes)
                        state.agent_speaking = True
                        state.got_audio = True
                        # Поки агент говорить — не вважаємо це тишею гравця.
                        state.last_user_voice = time.monotonic()

                    sc = getattr(response, "server_content", None)
                    if sc is None:
                        continue

                    it = getattr(sc, "input_transcription", None)
                    if it is not None and getattr(it, "text", None):
                        state.user_buf += it.text
                        state.last_user_voice = time.monotonic()

                    ot = getattr(sc, "output_transcription", None)
                    if ot is not None and getattr(ot, "text", None):
                        state.model_buf += ot.text
                        if not state.won and self._win_stem and (
                            self._win_stem in _normalize(state.model_buf)
                        ):
                            state.won = True
                            log.info("🗝️  Таємне слово назване — квест пройдено.")

                    if getattr(sc, "interrupted", False):
                        self.audio.stop_playback()

                    if getattr(sc, "turn_complete", False):
                        # Хід моделі завершено — агент договорив.
                        state.agent_speaking = False
                        if transcript:
                            if state.user_buf.strip():
                                log.info("👤 Гравець: %s", state.user_buf.strip())
                            if state.model_buf.strip():
                                log.info("🧙 %s: %s",
                                         self.character.display_name,
                                         state.model_buf.strip())
                        state.user_buf = ""
                        state.model_buf = ""
                        if state.won:
                            await self.audio.wait_output_drained()
                            state.outcome = Outcome.WON
                            end.set()
                            return

                if not got_message:
                    # Ітератор завершився без повідомлень → з'єднання закрите.
                    log.debug("Потік прийому порожній — з'єднання закрите.")
                    break
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            log.error("receive(): %s", exc)
            if state.outcome is None:
                state.outcome = Outcome.ERROR
            end.set()

    # ── сторож бездіяльності ─────────────────────────────────────────────────

    async def _watchdog(self, state: _State, end: asyncio.Event) -> None:
        timeout = self.cfg.session.inactivity_timeout_s
        try:
            while not end.is_set():
                await asyncio.sleep(1.0)
                if state.won:
                    continue
                idle = time.monotonic() - state.last_user_voice
                if idle > timeout:
                    log.info("Гравець мовчить %.0f с — засинаємо.", idle)
                    state.outcome = Outcome.TIMEOUT
                    end.set()
                    return
        except asyncio.CancelledError:
            raise

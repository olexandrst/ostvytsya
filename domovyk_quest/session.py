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


def _summarize_response(response) -> str:
    """Стислий дамп відповіді Live API для діагностики (рівень DEBUG).

    Не виводить самі байти аудіо — лише їх кількість — щоб не заливати лог.
    """
    bits: list[str] = []
    sc = getattr(response, "server_content", None)
    if sc is not None:
        parts_info = []
        mt = getattr(sc, "model_turn", None)
        if mt is not None and getattr(mt, "parts", None):
            for part in mt.parts:
                inline = getattr(part, "inline_data", None)
                if inline is not None and getattr(inline, "data", None):
                    parts_info.append(f"audio({len(inline.data)}b)")
                elif getattr(part, "text", None):
                    parts_info.append(f"text={part.text!r}")
                elif getattr(part, "thought", None):
                    parts_info.append("thought")
                else:
                    parts_info.append(f"other={part!r}")
        bits.append(f"parts=[{', '.join(parts_info)}]")
        for flag in ("turn_complete", "interrupted", "generation_complete"):
            if getattr(sc, flag, False):
                bits.append(flag)
        it = getattr(sc, "input_transcription", None)
        if it is not None and getattr(it, "text", None):
            bits.append(f"input_transcription={it.text!r}")
        ot = getattr(sc, "output_transcription", None)
        if ot is not None and getattr(ot, "text", None):
            bits.append(f"output_transcription={ot.text!r}")
    else:
        bits.append("server_content=None")
    for attr in ("go_away", "usage_metadata", "tool_call", "tool_call_cancellation"):
        val = getattr(response, attr, None)
        if val is not None:
            bits.append(f"{attr}={val}")
    return " ".join(bits)


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
    # Відновлення сесії при обриві WebSocket (1011 тощо), щоб не втратити квест.
    resumption_handle: Optional[str] = None
    got_message_this_conn: bool = False  # чи це з'єднання встигло щось прийняти
    consec_failures: int = 0             # поспіль «мертвих» з'єднань (для стелі спроб)


class QuestSession:
    def __init__(self, client, cfg: AppConfig, audio: AudioIO) -> None:
        self.client = client
        self.cfg = cfg
        self.audio = audio
        self.character = cfg.character
        # Стем таємного слова, щоб ловити будь-який відмінок ("Лабуда"/"Лабуду").
        w = _normalize(self.character.win_word).strip()
        self._win_stem = w[:-1] if len(w) > 4 else w

    def _live_config(self, resume_handle: Optional[str] = None) -> types.LiveConnectConfig:
        sys_text = build_system_instruction(self.character)
        kwargs = dict(
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
        # Стиснення контексту — щоб довга сесія (до 30 хв з паузами) не впиралася
        # в ліміт тривалості живого з'єднання й не обривалася сама собою.
        if self.cfg.session.context_compression:
            kwargs["context_window_compression"] = types.ContextWindowCompressionConfig(
                sliding_window=types.SlidingWindow()
            )
        # Відновлення сесії — сервер шле «handle», за яким при обриві (1011)
        # можна перепідключитися й продовжити розмову без втрати контексту.
        if self.cfg.session.session_resumption:
            kwargs["session_resumption"] = types.SessionResumptionConfig(
                handle=resume_handle
            )
        return types.LiveConnectConfig(**kwargs)

    async def run(self) -> Outcome:
        """Провести один квест від пробудження до завершення.

        Тримає розмову живою через ланцюжок з'єднань: якщо WebSocket обривається
        (серверний 1011 / ліміт тривалості), перепідключаємося за resumption-
        handle і продовжуємо той самий квест, доки не буде перемоги, тайм-ауту
        бездіяльності чи загального ліміту тривалості.
        """
        self.audio.drain_mic()
        state = _State()
        end = asyncio.Event()
        deadline = time.monotonic() + self.cfg.session.max_duration_s
        first = True
        try:
            while not end.is_set() and time.monotonic() < deadline:
                dropped = await self._run_one_connection(state, end, deadline, first)
                first = False
                if end.is_set() or not dropped:
                    break
                if state.consec_failures > self.cfg.session.max_reconnects:
                    log.error("Забагато обривів з'єднання поспіль (%d) — завершую квест.",
                              state.consec_failures)
                    if state.outcome is None:
                        state.outcome = Outcome.ERROR
                    break
                if time.monotonic() >= deadline:
                    break
                backoff = min(self.cfg.session.reconnect_backoff_s * state.consec_failures, 8.0)
                log.info("З'єднання обірвалося — перепідключаюся через %.1f с…", backoff)
                await asyncio.sleep(backoff)
                self.audio.drain_mic()
            if state.outcome is None and time.monotonic() >= deadline:
                log.info("Досягнуто ліміт тривалості квесту.")
                state.outcome = Outcome.TIMEOUT
        except asyncio.CancelledError:
            return Outcome.ABORTED
        except Exception as exc:  # noqa: BLE001
            log.error("Помилка сесії Gemini Live: %s", exc)
            return Outcome.ERROR
        finally:
            self.audio.stop_playback()
        return state.outcome or Outcome.TIMEOUT

    async def _run_one_connection(
        self, state: _State, end: asyncio.Event, deadline: float, first: bool
    ) -> bool:
        """Одне з'єднання. Повертає True, якщо воно обірвалося й треба відновити."""
        conn_lost = asyncio.Event()
        state.got_message_this_conn = False
        try:
            async with self.client.aio.live.connect(
                model=self.cfg.gemini.model,
                config=self._live_config(resume_handle=state.resumption_handle),
            ) as session:
                if first:
                    log.info("Сесію Gemini Live відкрито (голос: %s)", self.character.voice)
                else:
                    # Після відновлення відкриваємо мікрофон, щоб дитина могла
                    # знову заговорити (агент уже не «в процесі мовлення»).
                    state.agent_speaking = False
                    log.info("Сесію Gemini Live відновлено — продовжую квест…")

                # Вітання й нудж — лише на першому з'єднанні. Після відновлення
                # персонаж уже привітався; контекст розмови збережено.
                if first and self.cfg.session.greeting_on_wake:
                    await self._send_greeting(session)

                tasks = [
                    asyncio.create_task(self._send_loop(session, state, end, conn_lost)),
                    asyncio.create_task(self._recv_loop(session, state, end, conn_lost)),
                    asyncio.create_task(self._watchdog(state, end, deadline)),
                ]
                if first and self.cfg.session.greeting_on_wake:
                    tasks.append(
                        asyncio.create_task(self._greeting_nudge(session, state, end))
                    )
                waiters = [
                    asyncio.create_task(end.wait()),
                    asyncio.create_task(conn_lost.wait()),
                ]
                try:
                    await asyncio.wait(waiters, return_when=asyncio.FIRST_COMPLETED)
                finally:
                    for t in tasks + waiters:
                        t.cancel()
                    await asyncio.gather(*tasks, *waiters, return_exceptions=True)
                    self.audio.stop_playback()
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            log.warning("З'єднання Gemini Live урвалося: %s", exc)
            conn_lost.set()

        dropped = conn_lost.is_set() and not end.is_set()
        if dropped:
            # «Продуктивне» з'єднання (щось прийняли) скидає лічильник — такі
            # обриви нормальні для довгих сесій. Лише геть «мертві» поспіль
            # з'єднання наближають до стелі спроб.
            state.consec_failures = 0 if state.got_message_this_conn else state.consec_failures + 1
        return dropped

    # ── проактивне вітання ───────────────────────────────────────────────────

    async def _send_greeting(self, session, method: str = "client_content") -> None:
        """Спонукати модель заговорити першою.

        Надійність «привітатися першим» у native-audio залежить від платформи й
        версії SDK/бекенду, тож підтримуємо два способи:
          * client_content — надсилає ЗАКРИТИЙ хід користувача (turn_complete=True);
            це канонічний сигнал «тепер відповідай», рекомендований документацією;
          * realtime       — трактує текст як живу активність користувача.
        Нудж (нижче) чергує обидва, щоб хоч один спрацював у цьому середовищі.
        """
        if method == "realtime":
            await session.send_realtime_input(text=GREETING_TRIGGER)
        else:
            await session.send_client_content(
                turns=types.Content(role="user", parts=[types.Part(text=GREETING_TRIGGER)]),
                turn_complete=True,
            )

    async def _greeting_nudge(self, session, state: _State, end: asyncio.Event) -> None:
        """Страховка: якщо персонаж не заговорив сам — повторно спонукаємо його.

        Іноді native-audio модель «проспинає» перший сигнал і чекає на голос
        дитини. Щоб персонаж гарантовано почав розмову першим, за кілька секунд
        тиші повторюємо сигнал, ЧЕРГУЮЧИ спосіб (client_content ⇄ realtime) —
        який-небудь із них зазвичай таки змушує модель відповісти.
        """
        methods = ("realtime", "client_content")
        for i in range(4):
            try:
                await asyncio.sleep(self.cfg.session.greeting_nudge_s)
            except asyncio.CancelledError:
                raise
            if end.is_set() or state.got_audio:
                return
            method = methods[i % len(methods)]
            log.info("Персонаж іще мовчить — повторно спонукаю привітатися (%s)…", method)
            try:
                await self._send_greeting(session, method=method)
            except Exception as exc:  # noqa: BLE001
                log.debug("greeting nudge (%s): %s", method, exc)

    # ── мікрофон → модель ────────────────────────────────────────────────────

    async def _send_loop(self, session, state: _State, end: asyncio.Event,
                         conn_lost: asyncio.Event) -> None:
        rate = self.cfg.audio.input_sample_rate
        threshold = self.cfg.audio.vad_rms_threshold
        mime = f"audio/pcm;rate={rate}"
        half_duplex = self.cfg.session.half_duplex
        guard_s = self.cfg.session.echo_guard_ms / 1000.0
        was_blocking = False
        while not end.is_set() and not conn_lost.is_set():
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
                conn_lost.set()
                break

    # ── модель → колонка ─────────────────────────────────────────────────────

    async def _recv_loop(self, session, state: _State, end: asyncio.Event,
                         conn_lost: asyncio.Event) -> None:
        transcript = self.cfg.logging.transcript
        try:
            while not end.is_set():
                # session.receive() віддає один хід і завершується на turn_complete,
                # тож зовнішній цикл потрібен для наступних ходів.
                got_message = False
                async for response in session.receive():
                    got_message = True
                    state.got_message_this_conn = True
                    log.debug("Live-повідомлення: %s", _summarize_response(response))

                    # Handle для відновлення сесії при майбутньому обриві.
                    sru = getattr(response, "session_resumption_update", None)
                    if sru is not None and getattr(sru, "new_handle", None):
                        state.resumption_handle = sru.new_handle

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
            # Обрив з'єднання (напр. 1011). НЕ завершуємо квест помилкою —
            # сигналізуємо про втрату з'єднання, run() спробує відновити сесію.
            log.warning("receive(): %s", exc)
        finally:
            if not end.is_set():
                conn_lost.set()

    # ── сторож бездіяльності ─────────────────────────────────────────────────

    async def _watchdog(self, state: _State, end: asyncio.Event, deadline: float) -> None:
        timeout = self.cfg.session.inactivity_timeout_s
        try:
            while not end.is_set():
                await asyncio.sleep(1.0)
                if time.monotonic() >= deadline:
                    log.info("Досягнуто ліміт тривалості квесту.")
                    if state.outcome is None:
                        state.outcome = Outcome.TIMEOUT
                    end.set()
                    return
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

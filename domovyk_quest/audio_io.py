"""Введення/виведення звуку для Raspberry Pi (мікрофон + колонка).

Використовує sounddevice (PortAudio). Окремі потоки:
  * вхід  — 16 кГц PCM16 моно (формат, який чекає Gemini Live);
  * вихід — 24 кГц PCM16 моно (формат, який повертає Gemini Live).

Мікрофонний колбек PortAudio працює в окремому потоці; кадри безпечно
передаються в asyncio через call_soon_threadsafe. Відтворення йде окремою
asyncio-таскою, тож «перебивання» (barge-in) робиться миттєвим скиданням черги.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Optional, Union

import numpy as np

try:
    import sounddevice as sd
except OSError as exc:  # PortAudio не встановлено в системі
    sd = None
    _SD_IMPORT_ERROR: Optional[BaseException] = exc
except ImportError as exc:
    sd = None
    _SD_IMPORT_ERROR = exc
else:
    _SD_IMPORT_ERROR = None

log = logging.getLogger("ostvytsya.audio")


def rms(pcm16: bytes) -> float:
    """Середньоквадратична гучність блоку PCM16 (0..32767)."""
    if not pcm16:
        return 0.0
    samples = np.frombuffer(pcm16, dtype=np.int16).astype(np.float32)
    if samples.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(samples * samples)))


def list_devices() -> str:
    if sd is None:
        return f"sounddevice недоступний: {_SD_IMPORT_ERROR}"
    return str(sd.query_devices())


class AudioIO:
    """Власник аудіопотоків. Один екземпляр на процес."""

    def __init__(self, cfg) -> None:
        if sd is None:
            raise RuntimeError(
                "Бібліотека sounddevice/PortAudio недоступна "
                f"({_SD_IMPORT_ERROR}). Встанови: pip install sounddevice, "
                "а в системі — libportaudio2 (apt install libportaudio2)."
            )
        self.cfg = cfg
        self.in_rate = cfg.input_sample_rate
        self.out_rate = cfg.output_sample_rate
        self.in_block = cfg.input_block_frames
        self.input_device = cfg.input_device
        self.output_device = cfg.output_device

        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._in_stream: Optional["sd.RawInputStream"] = None
        self._out_stream: Optional["sd.RawOutputStream"] = None
        self._mic_q: asyncio.Queue[bytes] = asyncio.Queue(maxsize=128)
        self._out_q: asyncio.Queue[Optional[bytes]] = asyncio.Queue()
        self._play_task: Optional[asyncio.Task] = None

    # ── життєвий цикл ────────────────────────────────────────────────────────

    async def start(self) -> None:
        self._loop = asyncio.get_running_loop()
        self._in_stream = sd.RawInputStream(
            samplerate=self.in_rate,
            channels=1,
            dtype="int16",
            blocksize=self.in_block,
            device=self.input_device,
            callback=self._on_mic,
        )
        self._out_stream = sd.RawOutputStream(
            samplerate=self.out_rate,
            channels=1,
            dtype="int16",
            device=self.output_device,
        )
        self._in_stream.start()
        self._out_stream.start()
        self._play_task = self._loop.create_task(self._play_worker())
        log.debug("Аудіо запущено: вхід %d Гц, вихід %d Гц", self.in_rate, self.out_rate)

    async def close(self) -> None:
        if self._play_task:
            await self._out_q.put(None)
            self._play_task.cancel()
            try:
                await self._play_task
            except (asyncio.CancelledError, Exception):
                pass
        for stream in (self._in_stream, self._out_stream):
            if stream is not None:
                try:
                    stream.stop()
                    stream.close()
                except Exception:
                    pass

    # ── мікрофон ─────────────────────────────────────────────────────────────

    def _on_mic(self, indata, frames, time_info, status) -> None:  # PortAudio thread
        if status:
            log.debug("Статус мікрофона: %s", status)
        data = bytes(indata)
        loop = self._loop
        if loop is not None:
            loop.call_soon_threadsafe(self._push_mic, data)

    def _push_mic(self, data: bytes) -> None:
        if self._mic_q.full():  # відкидаємо найстаріший кадр, щоб не відставати
            try:
                self._mic_q.get_nowait()
            except asyncio.QueueEmpty:
                pass
        try:
            self._mic_q.put_nowait(data)
        except asyncio.QueueFull:
            pass

    async def read(self) -> bytes:
        """Наступний блок із мікрофона (блокує до появи кадру)."""
        return await self._mic_q.get()

    def drain_mic(self) -> None:
        """Викинути накопичені кадри (напр. перед стартом нового квесту)."""
        try:
            while True:
                self._mic_q.get_nowait()
        except asyncio.QueueEmpty:
            pass

    # ── колонка ──────────────────────────────────────────────────────────────

    def play(self, pcm16: bytes) -> None:
        """Поставити блок у чергу відтворення (неблокуюче)."""
        if pcm16:
            self._out_q.put_nowait(pcm16)

    def stop_playback(self) -> None:
        """Barge-in: миттєво скинути все, що ще не прозвучало."""
        try:
            while True:
                self._out_q.get_nowait()
        except asyncio.QueueEmpty:
            pass

    @property
    def output_idle(self) -> bool:
        return self._out_q.empty()

    async def wait_output_drained(self, tail_s: float = 0.6) -> None:
        """Дочекатися, поки відіграє всі поставлені блоки (+ короткий хвіст)."""
        while not self._out_q.empty():
            await asyncio.sleep(0.03)
        await asyncio.sleep(tail_s)

    async def _play_worker(self) -> None:
        assert self._loop is not None
        while True:
            chunk = await self._out_q.get()
            if chunk is None:
                break
            try:
                await self._loop.run_in_executor(None, self._out_stream.write, chunk)
            except Exception as exc:  # noqa: BLE001
                log.debug("Помилка відтворення: %s", exc)

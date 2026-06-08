"""Інтерфейс детектора кодового слова (режим спокою)."""

from __future__ import annotations

import abc

from ..audio_io import AudioIO


class WakeGate(abc.ABC):
    """Чекає, доки поряд із лялькою не пролунає кодове слово."""

    @abc.abstractmethod
    async def wait_for_wake(self, audio: AudioIO) -> bool:
        """Блокує до виявлення кодового слова. True — почуто, False — зупинка."""
        raise NotImplementedError

    async def close(self) -> None:  # за потреби
        return None

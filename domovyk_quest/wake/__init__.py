"""Фабрика детекторів кодового слова."""

from __future__ import annotations

from ..config import AppConfig
from .base import WakeGate


def create_wake_gate(cfg: AppConfig, client=None) -> WakeGate:
    mode = cfg.wake.mode
    if mode == "vosk":
        from .vosk_wake import VoskWakeGate
        return VoskWakeGate(cfg)
    if mode == "gemini":
        if client is None:
            raise ValueError("Режим wake.mode=gemini потребує клієнт Gemini.")
        from .gemini_wake import GeminiWakeGate
        return GeminiWakeGate(client, cfg)
    if mode == "manual":
        from .manual_wake import ManualWakeGate
        return ManualWakeGate(cfg)
    raise ValueError(f"Невідомий wake.mode: {mode!r}")


__all__ = ["WakeGate", "create_wake_gate"]

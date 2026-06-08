"""Локальний офлайн-детектор кодового слова на базі Vosk.

Рекомендований режим для постійно ввімкненої ляльки: працює офлайн, нічого не
надсилає в хмару й нічого не коштує, поки не пролунало кодове слово. Лише після
розпізнавання слова запускається сесія Gemini Live.

Потрібна модель Vosk для української (див. README, секція «Vosk»).
"""

from __future__ import annotations

import json
import logging
from pathlib import Path

from ..audio_io import AudioIO
from .base import WakeGate

log = logging.getLogger("ostvytsya.wake.vosk")


def _ratio(a: str, b: str) -> float:
    """Схожість двох рядків 0..1 на основі відстані Левенштейна."""
    if a == b:
        return 1.0
    if not a or not b:
        return 0.0
    la, lb = len(a), len(b)
    prev = list(range(lb + 1))
    for i in range(1, la + 1):
        cur = [i] + [0] * lb
        for j in range(1, lb + 1):
            cost = 0 if a[i - 1] == b[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        prev = cur
    dist = prev[lb]
    return 1.0 - dist / max(la, lb)


class VoskWakeGate(WakeGate):
    def __init__(self, cfg) -> None:
        try:
            from vosk import KaldiRecognizer, Model, SetLogLevel
        except ImportError as exc:  # noqa: F841
            raise RuntimeError(
                "Режим wake.mode=vosk потребує пакет vosk: pip install vosk. "
                "Або переключися на wake.mode=gemini / manual у config.yaml."
            ) from exc

        model_path = Path(cfg.wake.vosk_model_path)
        if not model_path.exists():
            raise RuntimeError(
                f"Не знайдено модель Vosk: {model_path}\n"
                "Завантаж українську модель (див. README → Vosk), напр.:\n"
                "  https://alphacephei.com/vosk/models\n"
                f"і розпакуй у {model_path}"
            )

        SetLogLevel(-1)  # тиша від Vosk у консолі
        self._KaldiRecognizer = KaldiRecognizer
        self._model = Model(str(model_path))
        self._rate = cfg.audio.input_sample_rate
        self._words = [w.lower().strip() for w in cfg.character.wake_words if w.strip()]
        self._fuzzy = cfg.wake.fuzzy
        self._threshold = cfg.wake.fuzzy_threshold
        # Грамата звужує розпізнавання до кодових слів — точніше й швидше.
        self._grammar = json.dumps(self._words + ["[unk]"], ensure_ascii=False)
        log.info("Vosk готовий. Кодові слова: %s", ", ".join(self._words))

    def _new_recognizer(self):
        try:
            rec = self._KaldiRecognizer(self._model, self._rate, self._grammar)
        except Exception:  # модель без підтримки грамати — звичайний режим
            rec = self._KaldiRecognizer(self._model, self._rate)
        rec.SetWords(False)
        return rec

    def _matches(self, text: str) -> bool:
        if not text:
            return False
        tokens = text.split()
        for w in self._words:
            if w in text:
                return True
            if self._fuzzy:
                for tok in tokens:
                    if _ratio(tok, w) >= self._threshold:
                        return True
        return False

    async def wait_for_wake(self, audio: AudioIO) -> bool:
        rec = self._new_recognizer()
        log.info("💤 Сплю. Чекаю кодове слово…")
        while True:
            data = await audio.read()
            if rec.AcceptWaveform(data):
                text = json.loads(rec.Result()).get("text", "").lower()
            else:
                text = json.loads(rec.PartialResult()).get("partial", "").lower()
            if self._matches(text):
                log.info("🔑 Почуто кодове слово: «%s»", text.strip())
                return True

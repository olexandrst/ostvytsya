"""Локальний офлайн-детектор кодового слова на базі Vosk.

Рекомендований режим для постійно ввімкненої ляльки: працює офлайн, нічого не
надсилає в хмару й нічого не коштує, поки не пролунало кодове слово.

ВАЖЛИВЕ ОБМЕЖЕННЯ Vosk: він розпізнає лише слова зі свого словника. Власні
назви (напр. «Оствиця») туди зазвичай НЕ входять, тож Vosk чує їх як щось
співзвучне («от свиця», «оствиться» тощо). Тому:
  * за замовчуванням вмикаємо ВІЛЬНЕ розпізнавання (без граматики) + нечіткий
    (fuzzy) збіг — так є шанс упіймати навіть спотворене слово;
  * у `wake_words` варто додати РЕАЛЬНІ варіанти, які чує Vosk — їх покаже
    режим калібрування:  python -m domovyk_quest --wake vosk --calibrate
  * якщо потрібна залізна надійність для власної назви — використай
    `--wake gemini` (розпізнає «Оствиця» точно).
"""

from __future__ import annotations

import json
import logging
import unicodedata
from pathlib import Path

from ..audio_io import AudioIO
from .base import WakeGate

log = logging.getLogger("ostvytsya.wake.vosk")


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s or "").lower()
    return "".join(ch if ch.isalnum() or ch.isspace() else " " for ch in s)


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
    return 1.0 - prev[lb] / max(la, lb)


class VoskWakeGate(WakeGate):
    def __init__(self, cfg) -> None:
        try:
            from vosk import KaldiRecognizer, Model, SetLogLevel
        except Exception as exc:  # noqa: BLE001
            raise RuntimeError(
                "Не вдалося імпортувати vosk. Встанови: pip install vosk\n"
                "Якщо збірка падає (частий випадок на дуже нових Python, напр. 3.14) —\n"
                "  • спробуй Python 3.11–3.12, або\n"
                "  • використай режим без vosk:  --wake gemini\n"
                f"Деталі: {exc}"
            ) from exc

        model_path = Path(cfg.wake.vosk_model_path)
        if not model_path.exists():
            raise RuntimeError(
                f"Не знайдено модель Vosk: {model_path}\n"
                "Завантаж українську модель (див. README → Vosk), напр.:\n"
                "  https://alphacephei.com/vosk/models "
                "(vosk-model-small-uk-v3-nano.zip)\n"
                f"і розпакуй у {model_path}"
            )

        SetLogLevel(-1)  # тиша від Kaldi у консолі
        self._KaldiRecognizer = KaldiRecognizer
        self._model = Model(str(model_path))
        self._rate = cfg.audio.input_sample_rate
        self._words = [_norm(w).strip() for w in cfg.character.wake_words if w.strip()]
        self._fuzzy = cfg.wake.fuzzy
        self._threshold = cfg.wake.fuzzy_threshold
        self._use_grammar = getattr(cfg.wake, "vosk_grammar", False)
        log.info("Vosk готовий. Кодові слова: %s | граматика: %s | fuzzy≥%.2f",
                 ", ".join(self._words), self._use_grammar, self._threshold)

    def _new_recognizer(self):
        # Граматика підвищує точність, АЛЕ мовчки не працює для слів поза
        # словником, тож за замовчуванням її не вмикаємо (вільне розпізнавання).
        if self._use_grammar and self._words:
            grammar = json.dumps(self._words + ["[unk]"], ensure_ascii=False)
            try:
                rec = self._KaldiRecognizer(self._model, self._rate, grammar)
            except Exception:  # noqa: BLE001
                rec = self._KaldiRecognizer(self._model, self._rate)
        else:
            rec = self._KaldiRecognizer(self._model, self._rate)
        rec.SetWords(False)
        return rec

    # ── зіставлення ──────────────────────────────────────────────────────────

    def _fuzzy_hit(self, text: str, word: str) -> bool:
        tokens = text.split()
        if not tokens:
            return False
        wlen = max(1, len(word.split()))
        max_n = min(len(tokens), wlen + 1)
        for n in range(1, max_n + 1):
            for i in range(len(tokens) - n + 1):
                span = tokens[i:i + n]
                for cand in (" ".join(span), "".join(span)):
                    if _ratio(cand, word) >= self._threshold:
                        return True
        return False

    def _matches(self, text: str) -> bool:
        t = _norm(text).strip()
        if not t:
            return False
        for w in self._words:
            if w and w in t:
                return True
            if self._fuzzy and self._fuzzy_hit(t, w):
                return True
        return False

    # ── очікування кодового слова ────────────────────────────────────────────

    async def wait_for_wake(self, audio: AudioIO) -> bool:
        rec = self._new_recognizer()
        log.info("💤 Сплю. Чекаю кодове слово…")
        while True:
            data = await audio.read()
            if rec.AcceptWaveform(data):
                text = json.loads(rec.Result()).get("text", "")
                if text.strip():
                    log.debug("vosk почув: «%s»", text.strip())
            else:
                text = json.loads(rec.PartialResult()).get("partial", "")
            if self._matches(text):
                log.info("🔑 Почуто кодове слово (Vosk: «%s»)", text.strip())
                return True

    # ── калібрування: показати, що саме чує Vosk ─────────────────────────────

    async def calibrate(self, audio: AudioIO) -> None:
        rec = self._new_recognizer()
        log.info("🎚️  КАЛІБРУВАННЯ Vosk. Промовляй кодове слово кілька разів —")
        log.info("    я показуватиму, ЯК я його чую. Додай ці варіанти у "
                 "wake_words свого персонажа. Ctrl+C — вихід.")
        last_partial = ""
        while True:
            data = await audio.read()
            if rec.AcceptWaveform(data):
                text = json.loads(rec.Result()).get("text", "").strip()
                if text:
                    hit = "  ✅ ЗБІГ" if self._matches(text) else ""
                    log.info("    ▶ фінал:  «%s»%s", text, hit)
                    last_partial = ""
            else:
                part = json.loads(rec.PartialResult()).get("partial", "").strip()
                if part and part != last_partial:
                    log.info("    · чую:   «%s»", part)
                    last_partial = part

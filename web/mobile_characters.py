"""Синхронізація персонажів між мобільними терміналами через панель.

Сервер тут — простий ретранслятор із правилом «останній запис перемагає»
(порівняння updated_at, unix-секунди): телефон на кожному такті надсилає
ПОВНИЙ набір своїх персонажів у мобільному JSON-форматі, сервер лишає собі
новіші версії та відповідає тими, що новіші за телефонні (або яких телефон
не має). Схему персонажа сервер НЕ тлумачить — документ зберігається як
непрозорий JSON (телефони самі валідують те, що отримують). Так мобільний
формат може розвиватись без жодних змін на сервері.

Надійність — через самовідновлення, а не через гарантії сховища: пам'ять +
best-effort файл data/mobile_characters.json. Навіть якщо сервер втратить
усе (рестарт, ефемерний диск), перший же такт синхронізації будь-якого
телефона наповнить сховище заново, а таймстампи гарантують, що старі версії
ніколи не затруть новіші.

Видалення синхронізується «надгробками»: телефон шле {id, deleted: true,
updated_at}, і цей документ бере участь у тому самому LWW-порівнянні, що й
живі персонажі, — тож видалення на одному терміналі доїжджає до всіх.
Виняток — незнищенні персонажі парку (PROTECTED_IDS): їхні надгробки сервер
відкидає, їх можна лише оновлювати.
"""

from __future__ import annotations

import json
import re
import threading
import time
from pathlib import Path
from typing import Any, Optional

# Розумні стелі, щоб зіпсований чи зловмисний клієнт не роздув сховище.
MAX_CHARACTERS = 200
MAX_CHAR_BYTES = 128 * 1024  # один персонаж: промпт ~10 КБ, із запасом

# Той самий формат id, що генерують телефони (CharacterStore._slugify).
_ID_RE = re.compile(r"^[a-z0-9_-]{1,64}$")

# Незнищенні персонажі парку: оновлювати можна, видаляти — ні. «Надгробки»
# для них відкидаються (дзеркало CharacterStore.protectedIds у мобільному
# застосунку; сервер — друга лінія оборони, напр. від телефона зі старим APK).
PROTECTED_IDS = frozenset({"domovychok", "povitrulya", "derevo"})

# Наскільки «в майбутнє» дозволяємо таймстамп (захист від кривого годинника
# на телефоні: інакше одна «отруєна» майбутня дата назавжди заблокувала б
# оновлення цього персонажа з усіх інших телефонів).
_MAX_CLOCK_SKEW_S = 300

_STORE_PATH = Path(__file__).resolve().parent.parent / "data" / "mobile_characters.json"


class MobileCharacterStore:
    def __init__(self, path: Path = _STORE_PATH) -> None:
        self._path = path
        self._lock = threading.Lock()
        self._chars: dict[str, dict[str, Any]] = {}
        self._load()

    # ── Диск (best-effort) ────────────────────────────────────────────────

    def _load(self) -> None:
        try:
            raw = json.loads(self._path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return
        except Exception:
            return  # зіпсований файл — почнемо з порожнього, телефони доллють
        if not isinstance(raw, dict):
            return
        for cid, doc in raw.items():
            if isinstance(cid, str) and _ID_RE.match(cid) and isinstance(doc, dict):
                self._chars[cid] = doc

    def _persist(self) -> None:
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._path.with_suffix(".tmp")
            tmp.write_text(
                json.dumps(self._chars, ensure_ascii=False), encoding="utf-8"
            )
            tmp.replace(self._path)
        except Exception:
            pass  # диск може бути read-only/ефемерним — сховище в пам'яті важливіше

    # ── Синхронізація ─────────────────────────────────────────────────────

    @staticmethod
    def _sanitize(raw: Any, now: int) -> Optional[dict[str, Any]]:
        """Мінімальна перевірка вхідного персонажа; None — відкинути."""
        if not isinstance(raw, dict):
            return None
        cid = raw.get("id")
        if not isinstance(cid, str) or not _ID_RE.match(cid):
            return None
        # Видалення (deleted: true) — звичайний документ-«надгробок» у тому
        # самому LWW-потоці; але для незнищенних персонажів його не існує.
        if raw.get("deleted") and cid in PROTECTED_IDS:
            return None
        try:
            ts = int(raw.get("updated_at") or 0)
        except (TypeError, ValueError):
            ts = 0
        doc = dict(raw)
        doc["updated_at"] = max(0, min(ts, now + _MAX_CLOCK_SKEW_S))
        try:
            if len(json.dumps(doc, ensure_ascii=False).encode()) > MAX_CHAR_BYTES:
                return None
        except (TypeError, ValueError):
            return None
        return doc

    def sync(self, incoming: Any) -> list[dict[str, Any]]:
        """Прийняти повний набір персонажів телефона, віддати те, чого йому бракує.

        Повертає персонажів, які на сервері новіші за надіслану телефоном
        версію, а також ті, яких телефон не надсилав узагалі.
        """
        now = int(time.time())
        if not isinstance(incoming, list):
            incoming = []
        reported: dict[str, int] = {}
        changed = False
        with self._lock:
            for raw in incoming[:MAX_CHARACTERS]:
                doc = self._sanitize(raw, now)
                if doc is None:
                    continue
                cid = doc["id"]
                # Для «відлуння» рівняємось на те, що телефон СКАЗАВ (без
                # обрізання майбутнього часу): вміст у нього вже точно є.
                try:
                    reported[cid] = max(0, int(raw.get("updated_at") or 0))
                except (TypeError, ValueError):
                    reported[cid] = 0
                cur = self._chars.get(cid)
                cur_ts = int(cur.get("updated_at") or 0) if cur else -1
                if doc["updated_at"] > cur_ts or cur is None:
                    if cid in self._chars or len(self._chars) < MAX_CHARACTERS:
                        self._chars[cid] = doc
                        changed = True
            out = [
                doc
                for cid, doc in self._chars.items()
                if reported.get(cid) is None
                or int(doc.get("updated_at") or 0) > reported[cid]
            ]
            if changed:
                self._persist()
        return out

    def count(self) -> int:
        with self._lock:
            return len(self._chars)


store = MobileCharacterStore()

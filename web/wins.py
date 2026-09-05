"""Перемоги команд: журнал подій «квест пройдено» від мобільних терміналів.

Коли команда проходить квест (персонаж назвав таємне слово), застосунок
надсилає подію в панель (POST /api/agents/win). Подія лягає в SQLite
(таблиця wins, domovyk_quest/db.py) і показується на сторінці терміналів:
скільки перемог у кожного термінала (усього / сьогодні), коли остання, і
список останніх перемог по парку.

Ідемпотентність: event_id події — ім'я сесії на телефоні (quest_<час>), тож
повторна доставка тієї самої події (телефон повторює, доки не отримає 200)
нічого не дублює — INSERT OR IGNORE.

Як і статуси, ендпойнт без логіна, тому кожне поле чиститься й обрізається,
а час перемоги затискається в розумні межі (годинник телефона може бути
кривим).
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from typing import Any, Optional

from domovyk_quest import db

from .agents import _clean_int, _clean_number, _clean_str

log = logging.getLogger("ostvytsya.wins")

# Скільки перемог тримаємо в базі щонайбільше — захист від сміттєвого потоку.
MAX_WINS = 20_000

# Наскільки «в минуле»/«в майбутнє» віримо годиннику телефона.
_MAX_PAST_S = 365 * 24 * 3600
_MAX_FUTURE_S = 5 * 60


@dataclass
class WinEvent:
    event_id: str
    agent_id: str
    character: Optional[str]
    character_id: Optional[str]
    won_at: float
    duration_s: Optional[int]
    run_number: Optional[int]
    app_version: Optional[str]
    received_at: float

    @property
    def duration_label(self) -> str:
        if self.duration_s is None:
            return "—"
        return f"{self.duration_s // 60} хв {self.duration_s % 60:02d} с"

    @property
    def when_label(self) -> str:
        t = time.localtime(self.won_at)
        today = time.localtime()
        clock = time.strftime("%H:%M", t)
        if (t.tm_year, t.tm_yday) == (today.tm_year, today.tm_yday):
            return f"сьогодні {clock}"
        return time.strftime("%d.%m.%Y", t) + f" {clock}"


@dataclass
class WinStats:
    total: int = 0
    today: int = 0
    last_won_at: Optional[float] = None

    @property
    def last_label(self) -> Optional[str]:
        if self.last_won_at is None:
            return None
        return WinEvent(
            "", "", None, None, self.last_won_at, None, None, None, 0.0
        ).when_label


def _row(r: Any) -> WinEvent:
    return WinEvent(
        event_id=str(r["event_id"]),
        agent_id=str(r["agent_id"]),
        character=r["character"],
        character_id=r["character_id"],
        won_at=float(r["won_at"]),
        duration_s=r["duration_s"],
        run_number=r["run_number"],
        app_version=r["app_version"],
        received_at=float(r["received_at"]),
    )


def record(payload: dict[str, Any]) -> Optional[WinEvent]:
    """Прийняти подію перемоги. None — у ній немає ідентифікатора термінала."""
    agent_id = _clean_str(payload.get("agent_id"), limit=64)
    if not agent_id:
        return None
    now = time.time()
    won_at = _clean_number(payload.get("won_at"))
    if won_at is None or won_at > now + _MAX_FUTURE_S or won_at < now - _MAX_PAST_S:
        won_at = now  # годинник телефона кривий — віримо своєму
    event_id = _clean_str(payload.get("event_id"), limit=96) or f"{agent_id}:{int(won_at)}"
    event = WinEvent(
        event_id=event_id,
        agent_id=agent_id,
        character=_clean_str(payload.get("character"), limit=80),
        character_id=_clean_str(payload.get("character_id"), limit=64),
        won_at=won_at,
        duration_s=_clean_int(payload.get("duration_s"), 0, 24 * 3600),
        run_number=_clean_int(payload.get("run_number"), 0, 1_000_000),
        app_version=_clean_str(payload.get("app_version"), limit=40),
        received_at=now,
    )
    try:
        with db.connect() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO wins (event_id, agent_id, character, character_id, "
                "won_at, duration_s, run_number, app_version, received_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (event.event_id, event.agent_id, event.character, event.character_id,
                 event.won_at, event.duration_s, event.run_number, event.app_version,
                 event.received_at),
            )
            (count,) = conn.execute("SELECT count(*) FROM wins").fetchone()
            if count > MAX_WINS:
                conn.execute(
                    "DELETE FROM wins WHERE event_id IN ("
                    "SELECT event_id FROM wins ORDER BY won_at ASC LIMIT ?)",
                    (count - MAX_WINS,),
                )
    except Exception:  # noqa: BLE001 — збій бази не має ламати відповідь телефону
        log.exception("Не вдалося зберегти перемогу")
    return event


def recent(limit: int = 50) -> list[WinEvent]:
    try:
        with db.connect() as conn:
            rows = conn.execute(
                "SELECT * FROM wins ORDER BY won_at DESC LIMIT ?", (int(limit),)
            ).fetchall()
        return [_row(r) for r in rows]
    except Exception:  # noqa: BLE001
        log.exception("Не вдалося прочитати перемоги")
        return []


def stats() -> dict[str, WinStats]:
    """Зведення по терміналах: усього, сьогодні (за локальним часом сервера), остання."""
    lt = time.localtime()
    day_start = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
    out: dict[str, WinStats] = {}
    try:
        with db.connect() as conn:
            rows = conn.execute(
                "SELECT agent_id, count(*) AS total, "
                "sum(CASE WHEN won_at >= ? THEN 1 ELSE 0 END) AS today, "
                "max(won_at) AS last_won_at FROM wins GROUP BY agent_id",
                (day_start,),
            ).fetchall()
        for r in rows:
            out[str(r["agent_id"])] = WinStats(
                total=int(r["total"] or 0),
                today=int(r["today"] or 0),
                last_won_at=float(r["last_won_at"]) if r["last_won_at"] is not None else None,
            )
    except Exception:  # noqa: BLE001
        log.exception("Не вдалося порахувати перемоги")
    return out

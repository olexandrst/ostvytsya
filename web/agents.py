"""Стан мобільних терміналів («агентів»), що звітують у веб-панель.

Кожен мобільний застосунок раз на кілька хвилин надсилає свій статус:
хто він, чи йде зараз квест, скільки заряду, де знаходиться. Панель
показує зведення по всіх терміналах.

Останній статус кожного термінала зберігається в SQLite (таблиця agents
спільної бази панелі, domovyk_quest/db.py): після перезапуску сервера
список терміналів на місці одразу, а не «через кілька хвилин, коли самі
відзвітують». У пам'яті лишається лише кеш для швидкого читання —
джерело правди в базі.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from dataclasses import asdict, dataclass, field, fields
from typing import Any, Optional

from domovyk_quest import db

log = logging.getLogger("ostvytsya.agents")

# Через скільки після останнього звіту вважати термінал офлайн. Звіти йдуть
# раз на 5 хвилин, тож даємо два пропущені такти плюс запас на мережу.
OFFLINE_AFTER_S = 12 * 60

# Скільки терміналів тримаємо максимум — захист від нескінченного росту,
# якщо хтось почне слати випадкові ідентифікатори.
MAX_AGENTS = 500


def _clean_str(value: Any, limit: int = 200) -> Optional[str]:
    """Рядок із чужого JSON: обрізаний, без керівних символів, або None."""
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    text = "".join(ch for ch in text if ch.isprintable())
    return text[:limit] or None


def _clean_number(value: Any) -> Optional[float]:
    if value is None or isinstance(value, bool):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number != number or number in (float("inf"), float("-inf")):
        return None
    return number


def _clean_int(value: Any, low: int, high: int) -> Optional[int]:
    number = _clean_number(value)
    if number is None:
        return None
    return max(low, min(high, int(number)))


@dataclass
class AgentStatus:
    """Останній відомий стан одного термінала."""

    agent_id: str
    received_at: float
    phone_number: Optional[str] = None
    quest_running: bool = False
    character: Optional[str] = None
    device_model: Optional[str] = None
    battery_percent: Optional[int] = None
    bluetooth: list[dict[str, Any]] = field(default_factory=list)
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    app_version: Optional[str] = None

    @property
    def online(self) -> bool:
        return (time.time() - self.received_at) <= OFFLINE_AFTER_S

    @property
    def seconds_ago(self) -> int:
        return max(0, int(time.time() - self.received_at))

    @property
    def coordinates(self) -> Optional[str]:
        if self.latitude is None or self.longitude is None:
            return None
        return f"{self.latitude:.5f}, {self.longitude:.5f}"

    @property
    def map_url(self) -> Optional[str]:
        if self.latitude is None or self.longitude is None:
            return None
        return f"https://www.google.com/maps?q={self.latitude},{self.longitude}"


_FIELD_NAMES = {f.name for f in fields(AgentStatus)}


class AgentRegistry:
    """Потокобезпечний реєстр останніх статусів із кешем поверх SQLite."""

    def __init__(self) -> None:
        self._agents: dict[str, AgentStatus] = {}
        self._lock = threading.Lock()
        self._loaded = False

    # ── база ──────────────────────────────────────────────────────────────

    def _ensure_loaded(self) -> None:
        """Підняти кеш із бази при першому зверненні (не при імпорті —
        щоб недоступна база не валила імпорт застосунку)."""
        if self._loaded:
            return
        with self._lock:
            if self._loaded:
                return
            try:
                with db.connect() as conn:
                    rows = conn.execute(
                        "SELECT agent_id, received_at, data FROM agents"
                    ).fetchall()
                for row in rows:
                    try:
                        data = json.loads(row["data"])
                        data = {k: v for k, v in data.items() if k in _FIELD_NAMES}
                        data["agent_id"] = str(row["agent_id"])
                        data["received_at"] = float(row["received_at"])
                        self._agents[data["agent_id"]] = AgentStatus(**data)
                    except (TypeError, ValueError):
                        continue  # пошкоджений рядок не має ламати список
            except Exception:  # noqa: BLE001 — база не має валити панель
                log.exception("Не вдалося прочитати статуси терміналів із бази")
            self._loaded = True

    @staticmethod
    def _persist(status: AgentStatus, evicted: Optional[str]) -> None:
        try:
            with db.connect() as conn:
                conn.execute(
                    "INSERT INTO agents (agent_id, received_at, data) VALUES (?, ?, ?) "
                    "ON CONFLICT(agent_id) DO UPDATE SET received_at = excluded.received_at, "
                    "data = excluded.data",
                    (status.agent_id, status.received_at,
                     json.dumps(asdict(status), ensure_ascii=False)),
                )
                if evicted:
                    conn.execute("DELETE FROM agents WHERE agent_id = ?", (evicted,))
        except Exception:  # noqa: BLE001 — збій диска не має ламати звіт термінала
            log.exception("Не вдалося зберегти статус термінала")

    # ── публічне ──────────────────────────────────────────────────────────

    def update(self, payload: dict[str, Any]) -> Optional[AgentStatus]:
        """Прийняти звіт. Повертає None, якщо в ньому немає ідентифікатора.

        Дані приходять ззовні, тож кожне поле чиститься й обрізається —
        панель показує їх людині, і сміття туди потрапити не повинно.
        """
        agent_id = _clean_str(payload.get("agent_id"), limit=64)
        if not agent_id:
            return None
        self._ensure_loaded()

        bluetooth: list[dict[str, Any]] = []
        raw_bt = payload.get("bluetooth")
        if isinstance(raw_bt, list):
            for item in raw_bt[:8]:
                if not isinstance(item, dict):
                    continue
                name = _clean_str(item.get("name"), limit=80)
                if not name:
                    continue
                bluetooth.append({
                    "name": name,
                    "battery": _clean_int(item.get("battery"), 0, 100),
                })

        status = AgentStatus(
            agent_id=agent_id,
            received_at=time.time(),
            phone_number=_clean_str(payload.get("phone_number"), limit=32),
            quest_running=bool(payload.get("quest_running")),
            character=_clean_str(payload.get("character"), limit=80),
            device_model=_clean_str(payload.get("device_model"), limit=80),
            battery_percent=_clean_int(payload.get("battery_percent"), 0, 100),
            bluetooth=bluetooth,
            latitude=_clean_number(payload.get("latitude")),
            longitude=_clean_number(payload.get("longitude")),
            app_version=_clean_str(payload.get("app_version"), limit=40),
        )

        evicted: Optional[str] = None
        with self._lock:
            # Переповнення реєстру: викидаємо той, від якого найдовше нічого
            # не чути, а не щойно доданий.
            if agent_id not in self._agents and len(self._agents) >= MAX_AGENTS:
                oldest = min(self._agents.values(), key=lambda a: a.received_at)
                self._agents.pop(oldest.agent_id, None)
                evicted = oldest.agent_id
            self._agents[agent_id] = status
        self._persist(status, evicted)
        return status

    def remove(self, agent_id: str) -> bool:
        """Прибрати термінал зі списку (кеш і база). Повертає False, якщо
        такого немає. Якщо телефон і далі працює, він знову з'явиться зі
        своїм наступним звітом (раз на 5 хвилин) — це прибирання саме
        «мертвих» записів: старих ідентифікаторів, списаних телефонів."""
        cleaned = _clean_str(agent_id, limit=64)
        if not cleaned:
            return False
        self._ensure_loaded()
        with self._lock:
            existed = self._agents.pop(cleaned, None) is not None
        try:
            with db.connect() as conn:
                cur = conn.execute("DELETE FROM agents WHERE agent_id = ?", (cleaned,))
                existed = existed or cur.rowcount > 0
        except Exception:  # noqa: BLE001 — кеш уже почищено; база доженеться
            log.exception("Не вдалося видалити термінал із бази")
        return existed

    def all(self) -> list[AgentStatus]:
        """Усі термінали: спершу активні, далі — за свіжістю звіту."""
        self._ensure_loaded()
        with self._lock:
            agents = list(self._agents.values())
        agents.sort(key=lambda a: (not a.online, -a.received_at))
        return agents


registry = AgentRegistry()

"""Налаштування логування: консоль + файл ./logs/ostvytsya_YYYY-MM-DD.log

Вимоги:
  * лог пишеться і в консоль, і у файл;
  * ім'я файлу містить сьогоднішню дату: ostvytsya_2026-07-04.log;
  * після рестарту в той самий день файл НЕ перезаписується, а ДОПИСУЄТЬСЯ
    (режим 'a', append);
  * опівночі обробник сам перемикається на новий файл за датою.
"""

from __future__ import annotations

import datetime
import logging
import os
from pathlib import Path


class DailyAppendFileHandler(logging.FileHandler):
    """FileHandler, що дозаписує у файл з датою в імені й котиться опівночі.

    На старті відкриває logs/<prefix>_<сьогодні>.log у режимі append. Під час
    роботи, якщо настав новий день, перемикається на новий файл.
    """

    def __init__(self, log_dir: str = "logs", prefix: str = "ostvytsya",
                 encoding: str = "utf-8") -> None:
        self._dir = Path(log_dir)
        self._prefix = prefix
        self._dir.mkdir(parents=True, exist_ok=True)
        self._current_date = self._today()
        super().__init__(self._path(self._current_date), mode="a",
                         encoding=encoding, delay=False)

    @staticmethod
    def _today() -> str:
        return datetime.date.today().isoformat()  # YYYY-MM-DD

    def _path(self, date_str: str) -> str:
        return str(self._dir / f"{self._prefix}_{date_str}.log")

    def _roll_if_needed(self) -> None:
        today = self._today()
        if today == self._current_date:
            return
        # Настав новий день — закриваємо старий файл, відкриваємо новий (append).
        self._current_date = today
        self.baseFilename = os.path.abspath(self._path(today))
        if self.stream:
            try:
                self.stream.close()
            finally:
                self.stream = None
        self.stream = self._open()

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self._roll_if_needed()
        except Exception:  # noqa: BLE001 — логування не має ронити застосунок
            pass
        super().emit(record)


def configure_logging(level: str, *, to_file: bool = True,
                      log_dir: str = "logs") -> None:
    """Налаштувати корінний логер: консоль + (опційно) файл із дозаписом."""
    root = logging.getLogger()
    root.setLevel(getattr(logging, level.upper(), logging.INFO))

    # Прибираємо попередні обробники (щоб повторний виклик не дублював рядки).
    for h in list(root.handlers):
        root.removeHandler(h)

    console = logging.StreamHandler()
    console.setFormatter(logging.Formatter("%(asctime)s  %(message)s", "%H:%M:%S"))
    root.addHandler(console)

    if to_file:
        try:
            fileh = DailyAppendFileHandler(log_dir=log_dir)
            # У файлі — повна дата, рівень і джерело (зручніше для розбору).
            fileh.setFormatter(logging.Formatter(
                "%(asctime)s %(levelname)-7s %(name)s: %(message)s",
                "%Y-%m-%d %H:%M:%S",
            ))
            root.addHandler(fileh)
            logging.getLogger("ostvytsya").info(
                "📝 Лог пишеться у %s", fileh.baseFilename
            )
        except Exception as exc:  # noqa: BLE001
            logging.getLogger("ostvytsya").warning(
                "Не вдалося відкрити лог-файл (%s) — пишу лише в консоль.", exc
            )

    # На DEBUG лишаємо внутрішні логери SDK видимими (мережева діагностика);
    # інакше приглушуємо їхній звичайний «шум» до WARNING.
    lib_level = logging.DEBUG if root.level <= logging.DEBUG else logging.WARNING
    logging.getLogger("google_genai").setLevel(lib_level)
    logging.getLogger("websockets").setLevel(lib_level)

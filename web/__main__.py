"""Запуск веб-додатка:  python -m web

Змінні середовища (див. .env.example):
    OPENAI_API_KEY          — ключ OpenAI (обов'язково для квесту)
    OSTVYTSYA_WEB_USER      — логін (типово «admin»)
    OSTVYTSYA_WEB_PASSWORD  — пароль
    OSTVYTSYA_WEB_SECRET    — ключ підпису сесійної куки
    OSTVYTSYA_WEB_HOST/PORT — де слухати (типово 127.0.0.1:8080)
"""

from __future__ import annotations

import argparse
import logging
import os
import sys


def _hosted() -> bool:
    """Чи ми на хостингу (Render/Railway/Fly/Heroku), а не на своєму комп'ютері.

    Хостинги передають порт через змінну PORT — це і є найнадійніша ознака.
    """
    return bool(os.environ.get("PORT") or os.environ.get("RENDER")
                or os.environ.get("RAILWAY_ENVIRONMENT")
                or os.environ.get("FLY_APP_NAME") or os.environ.get("DYNO"))


def _default_host() -> str:
    if os.environ.get("OSTVYTSYA_WEB_HOST"):
        return os.environ["OSTVYTSYA_WEB_HOST"]
    # На хостингу слухаємо всі інтерфейси, інакше платформа не побачить порт
    # («No open ports detected on 0.0.0.0»). Локально лишаємо тільки localhost.
    return "0.0.0.0" if _hosted() else "127.0.0.1"


def _default_port() -> int:
    # PORT (стандарт хостингів) має пріоритет: Render сам обирає номер порту.
    for name in ("PORT", "OSTVYTSYA_WEB_PORT"):
        value = (os.environ.get(name) or "").strip()
        if value.isdigit():
            return int(value)
    return 8080


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="web", description="Веб-квест «Оствиця» (OpenAI Realtime)")
    p.add_argument("--host", default=_default_host())
    p.add_argument("--port", type=int, default=_default_port())
    p.add_argument("--reload", action="store_true", help="перезапуск при зміні коду (розробка)")
    p.add_argument("--hash-password", metavar="PAROL",
                   help="порахувати хеш пароля для OSTVYTSYA_WEB_PASSWORD_HASH і вийти")
    p.add_argument("--set-admin-password", metavar="PAROL",
                   help="задати новий пароль адміністратора в базі панелі й вийти "
                        "(якщо забув старий)")
    args = p.parse_args(argv)

    if args.hash_password:
        from .auth import hash_password
        print(hash_password(args.hash_password))
        return 0

    if args.set_admin_password:
        # Імпорт web.app читає .env і створює адміністратора, якщо його ще
        # немає, — тож після цього рядок у базі гарантовано є.
        from .app import INITIAL_PASSWORD_FILE, auth
        from .auth import AuthError
        try:
            auth.set_password(auth.user, args.set_admin_password)
        except AuthError as exc:
            print(f"❌ {exc}", file=sys.stderr)
            return 1
        INITIAL_PASSWORD_FILE.unlink(missing_ok=True)
        print(f"✅ Пароль адміністратора «{auth.user}» змінено.")
        return 0

    try:
        import uvicorn
    except ImportError:
        print("❌ Не встановлено веб-залежності. Виконай:\n"
              "    pip install -r requirements-web.txt", file=sys.stderr)
        return 1

    logging.basicConfig(level=logging.INFO, format="%(asctime)s  %(message)s",
                        datefmt="%H:%M:%S")

    # Імпорт web.app читає .env (див. app.py), тож стан оточення перевіряємо після нього.
    from .app import _ENV_PATH, INITIAL_PASSWORD_FILE, auth
    from domovyk_quest import db
    from domovyk_quest.envfile import mask

    if _ENV_PATH:
        print(f"📄 Прочитано налаштування з {_ENV_PATH}")
    else:
        print("⚠️  Файл .env не знайдено — читаю лише змінні середовища.", file=sys.stderr)

    openai_key = os.environ.get("OPENAI_API_KEY", "")
    if openai_key:
        print(f"🔑 OPENAI_API_KEY: {mask(openai_key)}")
    else:
        print("⚠️  Не задано OPENAI_API_KEY — квест не запуститься. "
              "Впиши ключ у файл .env (саме .env, не .env.example).", file=sys.stderr)

    print(f"🗄️  База панелі (SQLite): {db.db_path()}")
    if not auth.configured:
        print("⚠️  Адміністратора не створено — база панелі недоступна "
              "(перевір OSTVYTSYA_DB_PATH чи права на теку data/). Вхід буде неможливий.",
              file=sys.stderr)
    elif INITIAL_PASSWORD_FILE.exists():
        print(f"🔑 Адміністратор «{auth.user}», початковий пароль — у файлі "
              f"{INITIAL_PASSWORD_FILE} (зміни його в панелі: /account).")
    else:
        print(f"👤 Адміністратор: «{auth.user}» (пароль — у базі; забув → "
              f"python -m web --set-admin-password …)")

    from domovyk_quest.characters_store import storage_backend
    backend = storage_backend()
    if backend == "postgresql":
        print("🗄️  Персонажі редактора: Render Managed PostgreSQL "
              "(storage.backend: postgresql)")
        if not (os.environ.get("DATABASE_URL") or "").strip():
            print("⚠️  DATABASE_URL не задано — з'єднання з PostgreSQL не вдасться. "
                  "Прив'яжи Managed PostgreSQL до сервісу в Render.", file=sys.stderr)
    elif backend == "files":
        print("🗄️  Персонажі редактора: файли characters/*.yaml (storage.backend: files)")
    else:
        print("🗄️  Персонажі редактора: та сама база SQLite (storage.backend: sqlite)")

    if _hosted():
        print(f"🌐 Слухаю {args.host}:{args.port} (хостинг сам віддасть публічну адресу)")
    else:
        print(f"🌐 Веб-квест на http://{args.host}:{args.port}")

    uvicorn.run(
        "web.app:app", host=args.host, port=args.port, reload=args.reload,
        # За зворотним проксі (Render та ін.) без цього застосунок вважає
        # з'єднання http-ним: ламаються редиректи й WebSocket (wss) для
        # Gemini-персонажів.
        proxy_headers=True,
        forwarded_allow_ips="*" if _hosted() else "127.0.0.1",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

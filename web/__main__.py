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


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="web", description="Веб-квест «Оствиця» (OpenAI Realtime)")
    p.add_argument("--host", default=os.environ.get("OSTVYTSYA_WEB_HOST", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.environ.get("OSTVYTSYA_WEB_PORT", "8080")))
    p.add_argument("--reload", action="store_true", help="перезапуск при зміні коду (розробка)")
    p.add_argument("--hash-password", metavar="PAROL",
                   help="порахувати хеш пароля для OSTVYTSYA_WEB_PASSWORD_HASH і вийти")
    args = p.parse_args(argv)

    if args.hash_password:
        from .auth import hash_password
        print(hash_password(args.hash_password))
        return 0

    try:
        import uvicorn
    except ImportError:
        print("❌ Не встановлено веб-залежності. Виконай:\n"
              "    pip install -r requirements-web.txt", file=sys.stderr)
        return 1

    logging.basicConfig(level=logging.INFO, format="%(asctime)s  %(message)s",
                        datefmt="%H:%M:%S")

    from .auth import Auth
    if not Auth().configured:
        print("⚠️  Не задано пароль (OSTVYTSYA_WEB_PASSWORD у .env) — вхід буде неможливий.",
              file=sys.stderr)

    print(f"🌐 Веб-квест на http://{args.host}:{args.port}")
    uvicorn.run("web.app:app", host=args.host, port=args.port, reload=args.reload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

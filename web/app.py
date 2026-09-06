"""Веб-додаток квест-агента «Оствиця» (OpenAI Realtime).

Дає в браузері те саме, що консольний агент робить у ляльці, плюс редактор:
  * список персонажів, створення / редагування / видалення;
  * вибір голосу та швидкості мовлення;
  * інтерактивний голосовий квест із обраним персонажем (WebRTC);
  * доступ лише за логіном і паролем.

Персонажі — ті самі YAML-файли, що їх читає консольний режим (characters/),
тож обидва режими працюють паралельно на спільних сценаріях.

Запуск:  python -m web            (або: uvicorn web.app:app --port 8080)
"""

from __future__ import annotations

import logging
import secrets
from pathlib import Path
from typing import Any, Optional

from fastapi import Depends, FastAPI, Form, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import (FileResponse, HTMLResponse, JSONResponse,
                               RedirectResponse, Response)
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware
from starlette.status import HTTP_303_SEE_OTHER

from domovyk_quest.envfile import load_env_file

from . import wins as win_log
from .agents import registry as agent_registry
from .mobile_characters import store as mobile_character_store

# Читаємо .env ДО того, як щось із нього знадобиться (Auth зчитує оточення
# одразу при створенні). Працює однаково на Linux/macOS і Windows.
_ENV_PATH, _ENV_KEYS = load_env_file()

from domovyk_quest.characters_store import (  # noqa: E402  (після завантаження .env)
    GEMINI_VOICE_LABELS,
    GEMINI_VOICES,
    OPENAI_VOICES,
    CharacterError,
    build_character,
    clone_character,
    delete_character,
    list_characters,
    read_raw,
    save_raw,
    slugify,
    storage_backend,
    validate_id,
)
from domovyk_quest.prompt import build_system_instruction  # noqa: E402

from .auth import MIN_PASSWORD_LENGTH, Auth, AuthError, session_secret
from .character_forms import payload_from_form as _payload_from_form
from .character_forms import resolve_system_prompt
from .gemini_live import model_name as gemini_model_name, run_quest as run_gemini_quest
from .realtime import GREETING_TRIGGER, RealtimeError, create_client_secret, model_name

log = logging.getLogger("ostvytsya.web")

BASE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = BASE_DIR.parent

def _https_only() -> bool:
    """Чи позначати сесійну куку як Secure (лише для HTTPS).

    На хостингах (Render та ін.) сайт завжди за HTTPS, тож куку варто захистити.
    Локально по http це вимкнено, інакше вхід просто не працював би.
    Можна задати вручну: OSTVYTSYA_WEB_HTTPS_ONLY=true|false.
    """
    import os
    explicit = (os.environ.get("OSTVYTSYA_WEB_HTTPS_ONLY") or "").strip().lower()
    if explicit in {"1", "true", "yes", "on"}:
        return True
    if explicit in {"0", "false", "no", "off"}:
        return False
    return bool(os.environ.get("PORT") or os.environ.get("RENDER")
                or os.environ.get("RAILWAY_ENVIRONMENT")
                or os.environ.get("FLY_APP_NAME") or os.environ.get("DYNO"))


app = FastAPI(title="Оствиця · квест-агент", docs_url=None, redoc_url=None)
app.add_middleware(
    SessionMiddleware,
    secret_key=session_secret(),
    session_cookie="ostvytsya_session",
    same_site="lax",           # захист від міжсайтових запитів
    https_only=_https_only(),  # на хостингу — Secure-кука
)
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))

auth = Auth()

# Файл із початковим паролем адміністратора — лише коли пароль довелося
# згенерувати самим (нічого не задано в .env). Зникає після першої зміни
# пароля в панелі. Лежить ПОРУЧ із базою (OSTVYTSYA_DB_PATH): на хостингу з
# постійним диском тека проєкту ефемерна, а тека бази — ні.
from domovyk_quest.db import db_path as _db_path  # noqa: E402

INITIAL_PASSWORD_FILE = _db_path().parent / "initial-admin-password.txt"


def _bootstrap_admin() -> None:
    """Створити єдиного адміністратора при першому старті."""
    try:
        generated = auth.ensure_admin()
    except Exception:  # noqa: BLE001 — панель має піднятись і сказати, що не так
        log.exception("Не вдалося створити адміністратора в базі панелі")
        return
    if not generated:
        return
    try:
        INITIAL_PASSWORD_FILE.parent.mkdir(parents=True, exist_ok=True)
        INITIAL_PASSWORD_FILE.write_text(generated + "\n", encoding="utf-8")
        try:
            INITIAL_PASSWORD_FILE.chmod(0o600)
        except OSError:
            pass
    except OSError:
        log.exception("Не вдалося записати початковий пароль у файл")
    log.warning(
        "🔑 Створено адміністратора «%s» із ВИПАДКОВИМ паролем: %s  "
        "(також у %s — зміни його в панелі: /account)",
        auth.user, generated, INITIAL_PASSWORD_FILE,
    )


_bootstrap_admin()


# ── доступ ───────────────────────────────────────────────────────────────────

def is_logged_in(request: Request) -> bool:
    return bool(request.session.get("user"))


def require_login(request: Request) -> str:
    """Залежність FastAPI: пускати далі лише автентифікованих."""
    user = request.session.get("user")
    if not user:
        raise HTTPException(status_code=401, detail="Потрібен вхід у систему.")
    return user


def csrf_token(request: Request) -> str:
    """Токен проти підробки міжсайтових запитів (CSRF)."""
    token = request.session.get("csrf")
    if not token:
        token = secrets.token_urlsafe(32)
        request.session["csrf"] = token
    return token


def check_csrf(request: Request, token: Optional[str]) -> None:
    expected = request.session.get("csrf")
    if not expected or not token or not secrets.compare_digest(token, expected):
        raise HTTPException(status_code=403, detail="Недійсний CSRF-токен. Онови сторінку.")


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    """401 у браузері — це редирект на сторінку входу, а не голий JSON."""
    accepts_html = "text/html" in (request.headers.get("accept") or "")
    if exc.status_code == 401 and accepts_html:
        return RedirectResponse(url="/login", status_code=HTTP_303_SEE_OTHER)
    return JSONResponse({"error": exc.detail}, status_code=exc.status_code)


# ── вхід / вихід ─────────────────────────────────────────────────────────────

@app.get("/login", response_class=HTMLResponse)
async def login_form(request: Request):
    if is_logged_in(request):
        return RedirectResponse(url="/", status_code=HTTP_303_SEE_OTHER)
    return templates.TemplateResponse(request, "login.html", {
        "csrf": csrf_token(request),
        "configured": auth.configured,
        "error": None,
    })


@app.post("/login", response_class=HTMLResponse)
async def login_submit(request: Request, username: str = Form(""),
                       password: str = Form(""), csrf: str = Form("")):
    check_csrf(request, csrf)
    authenticated = auth.authenticate(username, password)
    if authenticated:
        request.session["user"] = authenticated
        # Новий CSRF-токен після входу (захист від фіксації сесії).
        request.session["csrf"] = secrets.token_urlsafe(32)
        return RedirectResponse(url="/", status_code=HTTP_303_SEE_OTHER)
    log.warning("Невдала спроба входу (логін: %r)", username[:40])
    return templates.TemplateResponse(request, "login.html", {
        "csrf": csrf_token(request),
        "configured": auth.configured,
        "error": "Невірний логін або пароль.",
    }, status_code=401)


@app.post("/logout")
async def logout(request: Request, csrf: str = Form("")):
    check_csrf(request, csrf)
    request.session.clear()
    return RedirectResponse(url="/login", status_code=HTTP_303_SEE_OTHER)


# ── обліковий запис (зміна пароля) ───────────────────────────────────────────

def _account_page(request: Request, user: str, *, error: Optional[str] = None,
                  notice: Optional[str] = None, status_code: int = 200):
    return templates.TemplateResponse(request, "account.html", {
        "user": user,
        "csrf": csrf_token(request),
        "error": error,
        "notice": notice,
        "min_length": MIN_PASSWORD_LENGTH,
    }, status_code=status_code)


@app.get("/account", response_class=HTMLResponse)
async def account_form(request: Request, user: str = Depends(require_login)):
    return _account_page(request, user)


@app.post("/account", response_class=HTMLResponse)
async def account_submit(request: Request, user: str = Depends(require_login),
                         current_password: str = Form(""), new_password: str = Form(""),
                         new_password2: str = Form(""), csrf: str = Form("")):
    check_csrf(request, csrf)
    if not auth.authenticate(user, current_password):
        log.warning("Невдала спроба зміни пароля (логін: %r)", user)
        return _account_page(request, user, error="Поточний пароль невірний.",
                             status_code=403)
    if new_password != new_password2:
        return _account_page(request, user, error="Нові паролі не збігаються.",
                             status_code=400)
    try:
        auth.set_password(user, new_password)
    except AuthError as exc:
        return _account_page(request, user, error=str(exc), status_code=400)
    # Початковий (згенерований) пароль більше не чинний — файл із ним зайвий.
    try:
        INITIAL_PASSWORD_FILE.unlink(missing_ok=True)
    except OSError:
        pass
    return _account_page(request, user, notice="Пароль змінено.")


# ── сторінки ─────────────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def index(request: Request, user: str = Depends(require_login)):
    return templates.TemplateResponse(request, "index.html", {
        "user": user,
        "csrf": csrf_token(request),
        "characters": list_characters(),
        "model": model_name(),
    })


@app.get("/characters/new", response_class=HTMLResponse)
async def character_new(request: Request, user: str = Depends(require_login)):
    return templates.TemplateResponse(request, "edit.html", {
        "user": user,
        "csrf": csrf_token(request),
        "creating": True,
        "char": {
            "id": "",
            "display_name": "",
            "provider": "openai",
            "openai_voice": "marin",
            "voice": "Charon",
            "speech_speed": 1.0,
            "system_prompt": "",
            "wake_words": "",
            "win_word": "",
        },
        "openai_voices": OPENAI_VOICES,
        "gemini_voices": GEMINI_VOICES,
        "gemini_voice_labels": GEMINI_VOICE_LABELS,
        "from_scenario": False,
    })


@app.get("/characters/{char_id}/edit", response_class=HTMLResponse)
async def character_edit(char_id: str, request: Request,
                         user: str = Depends(require_login)):
    try:
        raw = read_raw(char_id)
    except CharacterError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    has_scenario = bool(raw.get("questions"))
    own_prompt = (raw.get("system_prompt") or "").strip()
    # У полі показуємо саме те, що реально йде в модель: власний промпт, якщо
    # він заданий, інакше — інструкцію, зібрану зі сценарію.
    effective_prompt = own_prompt or build_system_instruction(build_character(raw))
    return templates.TemplateResponse(request, "edit.html", {
        "user": user,
        "csrf": csrf_token(request),
        "creating": False,
        "char": {
            "id": char_id,
            "display_name": raw.get("display_name") or char_id,
            "provider": raw.get("provider") or "openai",
            "openai_voice": raw.get("openai_voice") or "marin",
            "voice": raw.get("voice") or "Charon",
            "speech_speed": raw.get("speech_speed") or 1.0,
            "system_prompt": effective_prompt,
            "wake_words": ", ".join(raw.get("wake_words") or []),
            "win_word": raw.get("win_word") or "",
        },
        "openai_voices": OPENAI_VOICES,
        "gemini_voices": GEMINI_VOICES,
        "gemini_voice_labels": GEMINI_VOICE_LABELS,
        # Промпт зібрано зі сценарію (а не написаний вручну) — про це варто сказати.
        "from_scenario": has_scenario and not own_prompt,
    })


@app.get("/quest/{char_id}", response_class=HTMLResponse)
async def quest_page(char_id: str, request: Request,
                     user: str = Depends(require_login)):
    try:
        raw = read_raw(char_id)
    except CharacterError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    provider = (raw.get("provider") or "openai").strip()
    is_google = provider == "google"
    return templates.TemplateResponse(request, "quest.html", {
        "user": user,
        "csrf": csrf_token(request),
        "char_id": char_id,
        "display_name": raw.get("display_name") or char_id,
        "provider": provider,
        "provider_label": "Google Gemini" if is_google else "OpenAI",
        "voice": (raw.get("voice") or "Charon") if is_google
                 else (raw.get("openai_voice") or "marin"),
        "model": gemini_model_name() if is_google else model_name(),
    })


# ── API персонажів ───────────────────────────────────────────────────────────
# _payload_from_form/resolve_system_prompt імпортовано з .character_forms —
# спільна логіка форми персонажа, щоб не дублювати правила в кількох місцях.

@app.post("/api/characters")
async def api_create(request: Request, user: str = Depends(require_login)):
    body = await request.json()
    check_csrf(request, body.get("csrf"))
    name = (body.get("display_name") or "").strip()
    char_id = (body.get("id") or "").strip() or slugify(name)
    try:
        char_id = validate_id(char_id)
        payload = _payload_from_form(body)
        save_raw(char_id, payload, create=True)
    except CharacterError as exc:
        return JSONResponse({"error": str(exc)}, status_code=400)
    log.info("Створено персонажа «%s» (%s)", name, char_id)
    return {"ok": True, "id": char_id}


@app.post("/api/characters/{char_id}")
async def api_update(char_id: str, request: Request,
                     user: str = Depends(require_login)):
    body = await request.json()
    check_csrf(request, body.get("csrf"))
    try:
        base = read_raw(char_id)          # зберігаємо сценарій недоторканим
        payload = _payload_from_form(body, base)
        # У формі показується ЕФЕКТИВНИЙ промпт. Якщо його не редагували, він
        # дослівно збігається з інструкцією, зібраною зі сценарію, — тоді нічого
        # не «фіксуємо» у system_prompt, і персонаж далі живе своїм YAML-сценарієм
        # (правки сценарію одразу відображатимуться в грі).
        payload = resolve_system_prompt(payload, base)
        save_raw(char_id, payload, create=False)
    except CharacterError as exc:
        return JSONResponse({"error": str(exc)}, status_code=400)
    log.info("Оновлено персонажа «%s»", char_id)
    return {"ok": True, "id": char_id}


@app.post("/api/characters/{char_id}/clone")
async def api_clone(char_id: str, request: Request,
                    user: str = Depends(require_login)):
    body = await request.json()
    check_csrf(request, body.get("csrf"))
    try:
        new_id, new_name = clone_character(char_id)
    except CharacterError as exc:
        return JSONResponse({"error": str(exc)}, status_code=400)
    log.info("Клоновано «%s» → «%s»", char_id, new_id)
    return {"ok": True, "id": new_id, "display_name": new_name}


@app.post("/api/characters/{char_id}/delete")
async def api_delete(char_id: str, request: Request,
                     user: str = Depends(require_login)):
    body = await request.json()
    check_csrf(request, body.get("csrf"))
    try:
        delete_character(char_id)
    except CharacterError as exc:
        return JSONResponse({"error": str(exc)}, status_code=400)
    log.info("Видалено персонажа «%s»", char_id)
    return {"ok": True}


# ── API квесту ───────────────────────────────────────────────────────────────

@app.post("/api/realtime/token/{char_id}")
async def api_realtime_token(char_id: str, request: Request,
                             user: str = Depends(require_login)):
    """Видати браузеру короткоживучий токен для WebRTC-сесії з персонажем."""
    body = await request.json()
    check_csrf(request, body.get("csrf"))
    try:
        character = build_character(read_raw(char_id))
    except CharacterError as exc:
        return JSONResponse({"error": str(exc)}, status_code=404)
    try:
        token = await create_client_secret(character)
    except RealtimeError as exc:
        log.error("Realtime-токен для «%s»: %s", char_id, exc)
        return JSONResponse({"error": str(exc)}, status_code=502)
    token["greeting"] = GREETING_TRIGGER
    return token


@app.get("/background.jpg")
async def background_image():
    """Фонове зображення сторінок.

    Лежить у корені проєкту (background.jpg) — так його зручно підмінити, не
    залазячи в статику. Якщо файлу немає, сторінки просто лишаються з
    градієнтним фоном.
    """
    for candidate in (
        PROJECT_ROOT / "background.jpg",
        PROJECT_ROOT / "background.jpeg",
        PROJECT_ROOT / "background.png",
        BASE_DIR / "static" / "background.jpg",
    ):
        if candidate.is_file():
            media = "image/png" if candidate.suffix == ".png" else "image/jpeg"
            return FileResponse(candidate, media_type=media,
                                headers={"Cache-Control": "public, max-age=3600"})
    raise HTTPException(status_code=404, detail="Фонове зображення не додано.")


@app.websocket("/ws/quest/{char_id}")
async def ws_quest(websocket: WebSocket, char_id: str):
    """Голосовий квест через Gemini Live (провайдер google).

    OpenAI-персонажі йдуть напряму з браузера по WebRTC, а Gemini працює по
    WebSocket із сирим PCM — його проводимо через сервер, щоб не світити ключ.
    """
    # WebSocket не проходить через Depends(require_login) — перевіряємо самі.
    # accept() ОБОВ'ЯЗКОВИЙ перед close(code=...): якщо закрити з'єднання до
    # рукостискання, сервер відхиляє його на рівні HTTP (403), і браузер бачить
    # абстрактний код 1006 замість заданого — код закриття долітає до клієнта
    # лише після accept().
    if not websocket.session.get("user"):
        await websocket.accept()
        await websocket.close(code=4401)
        return
    try:
        character = build_character(read_raw(char_id))
    except CharacterError:
        await websocket.accept()
        await websocket.close(code=4404)
        return

    await websocket.accept()
    try:
        await run_gemini_quest(websocket, character)
    except WebSocketDisconnect:
        pass
    finally:
        try:
            await websocket.close()
        except RuntimeError:
            pass  # уже закрито


# ── Термінали (мобільні агенти) ──────────────────────────────────────────────

@app.post("/api/agents/status")
async def api_agent_status(request: Request):
    """Прийняти звіт від мобільного термінала.

    Ендпойнт НАВМИСНО без логіна: телефони в парку не мають сесійної куки, а
    заводити для них окремий механізм автентифікації заради статусу —
    надлишково. Дані сюди йдуть неконфіденційні, а сам реєстр обмежений
    згори, тож найгірше, що дає відкритий ендпойнт, — сміттєвий рядок у
    таблиці. Саму панель видно лише після логіна.

    Відповідаємо 200 навіть на негодящий звіт: телефон нічого не зможе з цим
    вдіяти, а зайві помилки в його логах тільки заважатимуть.
    """
    try:
        payload = await request.json()
    except Exception:
        payload = None
    if not isinstance(payload, dict):
        return JSONResponse({"status": "ignored"}, status_code=200)
    status = agent_registry.update(payload)
    if status is None:
        return JSONResponse({"status": "ignored"}, status_code=200)
    return JSONResponse({"status": "ok", "interval_s": 300})


@app.post("/api/characters-sync")
async def api_characters_sync(request: Request):
    """Синхронізація персонажів між терміналами («останній запис перемагає»).

    Шлях навмисно НЕ /api/characters/sync: його з'їдав би зареєстрований
    раніше маршрут /api/characters/{char_id} (сприймаючи «sync» як id).

    Телефон надсилає повний набір своїх персонажів (мобільний JSON-формат із
    updated_at), у відповідь отримує ті, що на сервері новіші, або яких у
    нього немає. Без логіна — з тих самих міркувань, що й /api/agents/status;
    вміст персонажів неконфіденційний, а телефони валідують усе, що
    отримують, тож найгірший наслідок відкритості — сміттєвий персонаж у
    списку, який легко видалити.
    """
    try:
        payload = await request.json()
    except Exception:
        payload = None
    if not isinstance(payload, dict):
        return JSONResponse({"status": "ignored"}, status_code=200)
    characters = mobile_character_store.sync(payload.get("characters"))
    return JSONResponse(
        {"status": "ok", "interval_s": 300, "characters": characters}
    )


@app.post("/api/agents/win")
async def api_agent_win(request: Request):
    """Подія «команда пройшла квест» від термінала.

    Без логіна — з тих самих міркувань, що й /api/agents/status. Телефон
    повторює надсилання, доки не отримає 200, тож подія має бути
    ідемпотентною: event_id = ім'я сесії на телефоні, дубль ігнорується.
    """
    try:
        payload = await request.json()
    except Exception:
        payload = None
    if not isinstance(payload, dict):
        return JSONResponse({"status": "ignored"}, status_code=200)
    event = win_log.record(payload)
    if event is None:
        return JSONResponse({"status": "ignored"}, status_code=200)
    return JSONResponse({"status": "ok"})


@app.get("/agents", response_class=HTMLResponse)
async def agents_page(request: Request, user: str = Depends(require_login)):
    agents = agent_registry.all()
    return templates.TemplateResponse(request, "agents.html", {
        "user": user,
        "csrf": csrf_token(request),
        "agents": agents,
        "online_count": sum(1 for a in agents if a.online),
        "win_stats": win_log.stats(),
        "recent_wins": win_log.recent(50),
        "model": model_name(),
    })


@app.head("/")
async def root_head():
    """Health-check хостингів (Render шле HEAD /) — інакше вони бачать 405."""
    return Response(status_code=200)


@app.get("/api/health")
async def api_health():
    return {
        "status": "ok",
        "model": model_name(),
        "auth_configured": auth.configured,
        "storage": storage_backend(),
    }

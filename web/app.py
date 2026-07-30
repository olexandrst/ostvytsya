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

# Читаємо .env ДО того, як щось із нього знадобиться (Auth зчитує оточення
# одразу при створенні). Працює однаково на Linux/macOS і Windows.
_ENV_PATH, _ENV_KEYS = load_env_file()

from domovyk_quest.characters_store import (  # noqa: E402  (після завантаження .env)
    GEMINI_VOICE_LABELS,
    GEMINI_VOICES,
    OPENAI_VOICES,
    PROVIDERS,
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

from .auth import Auth, session_secret
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
    if auth.check(username, password):
        request.session["user"] = auth.user
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

def _payload_from_form(form: dict[str, Any], base: Optional[dict[str, Any]] = None
                       ) -> dict[str, Any]:
    """Скласти YAML-словник персонажа, зберігши поля, яких немає у формі.

    Це важливо: у формі редагуються лише назва/голос/промпт, а persona, style,
    questions, directives тощо мають лишитися недоторканими.
    """
    data = dict(base or {})
    data["display_name"] = (form.get("display_name") or "").strip()
    provider = (form.get("provider") or data.get("provider") or "openai").strip()
    data["provider"] = provider if provider in PROVIDERS else "openai"
    data["openai_voice"] = (form.get("openai_voice") or "marin").strip()
    data["voice"] = (form.get("voice") or data.get("voice") or "Charon").strip()
    data["system_prompt"] = (form.get("system_prompt") or "").strip()
    try:
        data["speech_speed"] = round(float(form.get("speech_speed") or 1.0), 2)
    except (TypeError, ValueError):
        data["speech_speed"] = 1.0

    words = [w.strip() for w in (form.get("wake_words") or "").split(",") if w.strip()]
    if words:
        data["wake_words"] = words
    elif not data.get("wake_words"):
        # Консольний режим вимагає кодового слова — тож даємо розумний типовий.
        data["wake_words"] = [data["display_name"]] if data["display_name"] else ["Оствиця"]

    win = (form.get("win_word") or "").strip()
    if win:
        data["win_word"] = win
    elif not data.get("win_word"):
        data["win_word"] = "Перемога"

    data.setdefault("language", "uk-UA")
    data.setdefault("persona", "")
    data.setdefault("style", [])
    data.setdefault("intro", "")
    data.setdefault("win", "")
    # Порожній власний промпт у файлі не тримаємо: його відсутність і означає
    # «персонаж живе своїм YAML-сценарієм».
    if not data.get("system_prompt"):
        data.pop("system_prompt", None)
    return data


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
        submitted = (payload.get("system_prompt") or "").strip()
        if submitted and base.get("questions"):
            scenario_prompt = build_system_instruction(
                build_character({**base, "system_prompt": ""})
            ).strip()
            if submitted == scenario_prompt:
                # Прибираємо ключ, а не ставимо порожній рядок: його відсутність
                # і означає «персонаж живе своїм YAML-сценарієм».
                payload.pop("system_prompt", None)
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
    if not websocket.session.get("user"):
        await websocket.close(code=4401)
        return
    try:
        character = build_character(read_raw(char_id))
    except CharacterError:
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

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

from fastapi import Depends, FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware
from starlette.status import HTTP_303_SEE_OTHER

from domovyk_quest.envfile import load_env_file

# Читаємо .env ДО того, як щось із нього знадобиться (Auth зчитує оточення
# одразу при створенні). Працює однаково на Linux/macOS і Windows.
_ENV_PATH, _ENV_KEYS = load_env_file()

from domovyk_quest.characters import (  # noqa: E402  (після завантаження .env)
    GEMINI_VOICES,
    OPENAI_VOICES,
    CharacterError,
    build_character,
    delete_character,
    list_characters,
    read_raw,
    save_raw,
    slugify,
    validate_id,
)
from domovyk_quest.prompt import build_system_instruction  # noqa: E402

from .auth import Auth, session_secret
from .realtime import GREETING_INSTRUCTION, RealtimeError, create_client_secret, model_name

log = logging.getLogger("ostvytsya.web")

BASE_DIR = Path(__file__).resolve().parent

app = FastAPI(title="Оствиця · квест-агент", docs_url=None, redoc_url=None)
app.add_middleware(
    SessionMiddleware,
    secret_key=session_secret(),
    session_cookie="ostvytsya_session",
    same_site="lax",   # захист від міжсайтових запитів
    https_only=False,  # у продакшені за HTTPS постав true
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
            "openai_voice": "marin",
            "voice": "Charon",
            "speech_speed": 1.0,
            "system_prompt": "",
            "wake_words": "",
            "win_word": "",
        },
        "openai_voices": OPENAI_VOICES,
        "gemini_voices": GEMINI_VOICES,
        "generated_prompt": "",
        "has_scenario": False,
    })


@app.get("/characters/{char_id}/edit", response_class=HTMLResponse)
async def character_edit(char_id: str, request: Request,
                         user: str = Depends(require_login)):
    try:
        raw = read_raw(char_id)
    except CharacterError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    character = build_character(raw)
    has_scenario = bool(raw.get("questions"))
    return templates.TemplateResponse(request, "edit.html", {
        "user": user,
        "csrf": csrf_token(request),
        "creating": False,
        "char": {
            "id": char_id,
            "display_name": raw.get("display_name") or char_id,
            "openai_voice": raw.get("openai_voice") or "marin",
            "voice": raw.get("voice") or "Charon",
            "speech_speed": raw.get("speech_speed") or 1.0,
            "system_prompt": raw.get("system_prompt") or "",
            "wake_words": ", ".join(raw.get("wake_words") or []),
            "win_word": raw.get("win_word") or "",
        },
        "openai_voices": OPENAI_VOICES,
        "gemini_voices": GEMINI_VOICES,
        # Показуємо, який промпт піде в модель зараз (зібраний зі сценарію).
        "generated_prompt": build_system_instruction(character),
        "has_scenario": has_scenario,
    })


@app.get("/quest/{char_id}", response_class=HTMLResponse)
async def quest_page(char_id: str, request: Request,
                     user: str = Depends(require_login)):
    try:
        raw = read_raw(char_id)
    except CharacterError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    return templates.TemplateResponse(request, "quest.html", {
        "user": user,
        "csrf": csrf_token(request),
        "char_id": char_id,
        "display_name": raw.get("display_name") or char_id,
        "voice": raw.get("openai_voice") or "marin",
        "model": model_name(),
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
        save_raw(char_id, payload, create=False)
    except CharacterError as exc:
        return JSONResponse({"error": str(exc)}, status_code=400)
    log.info("Оновлено персонажа «%s»", char_id)
    return {"ok": True, "id": char_id}


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
    token["greeting"] = GREETING_INSTRUCTION
    return token


@app.get("/api/health")
async def api_health():
    return {"status": "ok", "model": model_name(), "auth_configured": auth.configured}

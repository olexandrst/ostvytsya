# 🌳 Голосовий квест-агент парку «Оствиця»

Інтерактивна лялька-оповідач для парку історичної реконструкції
[**«Оствиця»**](https://ostvytsya.com.ua/) (Рівне). Лялька **«Домовичок»** висить на
дереві, всередині — **Raspberry Pi Zero 2 W** з мікрофоном і колонкою. Лялька «спить»
і **не реагує ні на що**, доки дитина не промовить кодове слово **«Оствиця»**. Тоді
персонаж оживає, голосом веде квест із трьох загадок і, коли всі розгадано, відкриває
таємне слово-нагороду **«Лабуда»**.

Голос і діалог — **Google Gemini Live API (Native Audio)**. Персонажі, голоси,
кодові слова та самі загадки — **у конфігурації**, тож одним кодом можна підняти
скільки завгодно різних героїв (приклад другого — Водяник).

> 📜 Людиночитний сценарій: [`scripts/quest-domovychok.md`](scripts/quest-domovychok.md)

---

## Як це працює

```
        режим СПОКОЮ                              режим КВЕСТУ
 ┌────────────────────────┐   "Оствиця"   ┌──────────────────────────────┐
 │ детектор кодового слова │ ───────────▶ │  Gemini Live  (Native Audio) │
 │ (Vosk, офлайн, тиша,    │              │  • персона + сценарій з YAML │
 │  нічого не коштує)      │ ◀─── reset ──│  • 3 загадки, підказки       │
 └────────────────────────┘  перемога/    │  • судить відповіді          │
        ▲        │            тайм-аут     │  • каже «Лабуда» → перемога  │
   мікрофон   колонка                      └──────────────────────────────┘
```

Розподіл ролей:

| Що | Хто робить |
|---|---|
| Сон до кодового слова, аудіо-ввід/вивід, скидання сесії, тайм-аути | **Python-каркас** |
| Жива розмова: загадки по черзі, оцінка відповідей, підказки, фінальне слово | **Модель Gemini** (за інструкцією зі сценарію) |

Логіку розмови веде модель — це робить діалог природним і дозволяє щедро
зараховувати відповіді (синоніми, відмінки), а не звіряти рядки в коді.

---

## Структура

```
ostvytsya/
├── config.yaml                  # рантайм: модель, аудіо, режим пробудження, тайм-аути
├── characters/
│   ├── domovychok.yaml          # ПЕРСОНАЖ + СЦЕНАРІЙ (Домовичок, слово «Лабуда»)
│   └── vodyanyk.yaml            # приклад 2-го персонажа (Водяник, інший голос/слово)
├── scripts/
│   └── quest-domovychok.md      # сценарій у читабельному вигляді
├── domovyk_quest/               # код агента
│   ├── __main__.py              # CLI
│   ├── orchestrator.py          # машина станів: спокій → квест → reset
│   ├── session.py               # сесія Gemini Live Native Audio (ядро квесту)
│   ├── prompt.py                # збирає системну інструкцію зі сценарію
│   ├── audio_io.py              # мікрофон + колонка (sounddevice), VAD, barge-in
│   ├── config.py                # завантаження/валідація конфігів
│   └── wake/                    # детектори кодового слова
│       ├── vosk_wake.py         #   офлайн (рекомендовано)
│       ├── gemini_wake.py       #   через Gemini Live
│       └── manual_wake.py       #   Enter (для тестів)
├── deploy/domovyk-quest.service # автозапуск через systemd
└── requirements.txt
```

---

## Швидкий старт (на ПК для перевірки)

```bash
# 1. Залежності
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
# у системі також потрібен PortAudio:
#   Debian/Ubuntu/RPi:  sudo apt install libportaudio2
#   macOS:              brew install portaudio

# 2. Ключ Gemini
cp .env.example .env        # впиши GEMINI_API_KEY
export $(grep -v '^#' .env | xargs)     # або просто: export GEMINI_API_KEY=...

# 3. Найшвидша перевірка — без розпізнавання слова та мікрофона для wake:
python -m domovyk_quest --wake manual --once
#   натисни Enter → говори у мікрофон → проходь квест голосом
```

Перевірити, які аудіопристрої бачить система:

```bash
python -m domovyk_quest --list-devices
# індекс або частину назви впиши у config.yaml → audio.input_device / output_device
```

---

## Локальне розпізнавання кодового слова (Vosk) — для постійної роботи

Рекомендований режим для ляльки, що працює весь день: **офлайн**, без передачі звуку в
хмару й без витрат, поки не пролунало кодове слово.

```bash
# Завантаж українську модель Vosk (легка ~45–50 МБ — добре для Pi Zero 2 W):
cd models
wget https://alphacephei.com/vosk/models/vosk-model-small-uk-v3-nano.zip
unzip vosk-model-small-uk-v3-nano.zip
mv vosk-model-small-uk-v3-nano vosk-model-small-uk
cd ..
```

Шлях до моделі вказано в `config.yaml → wake.vosk_model_path`. Запуск:

```bash
python -m domovyk_quest          # wake.mode=vosk за замовчуванням
```

> Альтернатива без Vosk: `wake.mode: gemini` — слово ловиться через Gemini Live (нуль
> зайвих залежностей, але постійний стрім у хмару = дорожче для цілодобової роботи).

---

## Конфігурація

**`config.yaml`** — «залізо» й рантайм:

| Поле | Призначення |
|---|---|
| `gemini.model` | модель Native Audio (див. нижче) |
| `gemini.api_key_env` | назва змінної середовища з ключем |
| `audio.input_device` / `output_device` | мікрофон / колонка (`null`=за замовч., індекс або назва) |
| `audio.vad_rms_threshold` | поріг гучності «гравець говорить» |
| `wake.mode` | `vosk` \| `gemini` \| `manual` |
| `session.half_duplex` | поки агент говорить — мікрофон не йде в модель (захист від відлуння; типово `true`) |
| `session.echo_guard_ms` | пауза після мовлення агента перед відкриттям мікрофона |
| `session.inactivity_timeout_s` | скільки терпіти тишу перед сном |
| `session.max_duration_s` | запобіжник максимальної тривалості |

**`characters/*.yaml`** — персонаж і сценарій: `display_name`, `voice`, `wake_words`,
`win_word`, `persona`, `style`, `intro`, `questions` (текст + `accepted` + `hints` +
`reveal`), `win`, `goodbye`, `fallbacks`. Жодного коду чіпати не треба.

Перевизначення з CLI:

```bash
python -m domovyk_quest --character characters/vodyanyk.yaml --voice Enceladus
python -m domovyk_quest --wake gemini --model gemini-2.5-flash-preview-native-audio-dialog
python -m domovyk_quest --log-level DEBUG
```

### Моделі Native Audio
У `config.yaml` за замовчуванням `gemini-2.5-flash-native-audio-preview-09-2025`.
Актуальні альтернативи (перевір у [документації](https://ai.google.dev/gemini-api/docs/live-api)):
`gemini-2.5-flash-native-audio-preview-12-2025`,
`gemini-2.5-flash-preview-native-audio-dialog`.

### Голоси
Передвстановлені голоси Gemini, напр.: `Puck`, `Charon`, `Kore`, `Fenrir`, `Aoede`,
`Leda`, `Orus`, `Zephyr`, `Enceladus`, `Iapetus`, `Algieba`, `Sadachbia`, `Sulafat` …
Задається у `characters/*.yaml → voice`. Домовичок — `Charon`, Водяник — `Enceladus`.

---

## Додати нового персонажа

1. `cp characters/domovychok.yaml characters/berehynia.yaml`
2. Зміни `id`, `display_name`, `voice`, `wake_words`, `win_word`, `persona`, три `questions`.
3. Запусти: `python -m domovyk_quest --character characters/berehynia.yaml`

Кожна лялька = свій Pi зі своїм файлом персонажа (або один Pi, який запускають із
потрібним `--character`).

---

## Розгортання на Raspberry Pi Zero 2 W

```bash
sudo apt update && sudo apt install -y python3-venv libportaudio2 git
git clone <repo> /home/pi/ostvytsya && cd /home/pi/ostvytsya
python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt
# завантаж модель Vosk (див. вище), створи .env із GEMINI_API_KEY
```

Автозапуск (systemd):

```bash
sudo cp deploy/domovyk-quest.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now domovyk-quest
journalctl -u domovyk-quest -f      # дивитись журнал
```

Поради для Pi Zero 2 W: бери **USB-мікрофон** або I²S-мікрофон + невеликий
підсилювач/колонку; перевір ALSA через `arecord -l` / `aplay -l`; для стабільності
тримай гарний Wi-Fi (Live API працює онлайн).

---

## Вартість і приватність

- У режимі **`vosk`** до кодового слова **нічого** не йде в хмару — лялька слухає
  локально. Витрати з'являються лише під час самого квесту (стрім у Gemini Live).
- У режимі **`gemini`** аудіо стрімиться постійно (дорожче для цілодобової роботи).
- Для дитячої інсталяції рекомендовано `vosk` + розумні тайм-аути (вже виставлені).

---

## Розв'язання проблем

| Симптом | Що робити |
|---|---|
| `sounddevice/PortAudio недоступний` | `sudo apt install libportaudio2`, `pip install sounddevice` |
| Не знайдено ключ API | `export GEMINI_API_KEY=...` або заповни `.env` |
| Не чує кодове слово (vosk) | перевір мікрофон (`--list-devices`), додай відмінки у `wake_words`, підніми `wake.fuzzy_threshold` нижче |
| **Агент перебиває сам себе / не договорює, «розмова сама із собою»** | акустичне відлуння: колонка → мікрофон. Має бути `session.half_duplex: true` (типово). Якщо все одно — підніми `session.echo_guard_ms` (напр. 700), зменш гучність колонки, віддали мікрофон від динаміка або візьми мікрофон з апаратним AEC |
| «Гравцем» розпізнається голос самого агента | те саме — відлуння; див. рядок вище (`half_duplex`) |
| Лялька говорить, але тихо/рве звук | зменш навантаження, перевір `output_device`, гучність ALSA (`alsamixer`) |
| Не тією мовою | переконайся, що `style`/`persona` наголошують українську; голос лишай із підтримкою uk |

---

*Зроблено для парку «Оствиця». Слава кмітливим мандрівникам! 🛶*

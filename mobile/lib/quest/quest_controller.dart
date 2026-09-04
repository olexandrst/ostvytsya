import 'dart:async';

import '../constants.dart';
import '../models/character.dart';
import '../services/character_store.dart';
import '../services/device_memory.dart';
import '../services/session_logger.dart';
import '../services/session_recorder.dart';
import '../services/settings_store.dart';
import 'audio_pipeline.dart';
import 'transcript_line.dart';
import 'transcript_utils.dart';
import 'transport.dart';
import 'wake_gate.dart';

export 'transcript_line.dart';

enum QuestPhase { listening, connecting, running, restarting, stopped }

enum QuestOutcome { won, timeout, error, aborted }

class QuestStatusUpdate {
  final QuestPhase phase;
  final QuestOutcome? lastOutcome;
  final int runCount;

  const QuestStatusUpdate(this.phase, {this.lastOutcome, this.runCount = 0});
}

/// Веде один персонаж по колу «сплю → чую кодове слово → квест →
/// перемога/тайм-аут → знову сплю» — доки користувач сам не зупинить. Порт
/// логіки domovyk_quest/orchestrator.py + session.py: спершу локально (без
/// мережі й без сесії Gemini/OpenAI) слухаємо кодове слово через
/// [WakeGateService], і лише почувши його — під'єднуємось і ведемо один
/// квест. Транспорт (Gemini/OpenAI) підмінний через [transportFactory].
class QuestController {
  QuestController({
    required this.character,
    required this.apiKey,
    required this.transportFactory,
  }) {
    // Показуємо, що саме чує локальний Vosk, поки персонаж "спить" — без
    // цього мовчазна відсутність активації виглядає однаково і при
    // непрацюючому мікрофоні/розпізнаванні, і при тому, що просто ще ніхто
    // не сказав кодове слово.
    wakeGate.diagnostics.listen((msg) => _say('system', msg));
    // Так само для вибору аудіо-пристрою під час самого квесту — щоб було
    // видно, чи автопідбір справді бачить і обирає зовнішній мікрофон.
    audio.diagnostics.listen((msg) => _say('system', msg));
  }

  /// Не final: термінал може тижнями стояти на цьому екрані, а персонажа тим
  /// часом відредагують на іншому телефоні й синхронізація принесе нову
  /// версію на диск — перед кожним циклом «сон → квест» перечитуємо її
  /// (див. _refreshCharacter), щоб правки застосовувались без перезаходу.
  Character character;
  final String apiKey;
  final QuestTransportFactory transportFactory;
  final AudioPipeline audio = AudioPipeline();
  final WakeGateService wakeGate = WakeGateService();
  final SessionRecorder _recorder = SessionRecorder();
  final SessionLogger _logger = SessionLogger();
  final SettingsStore _settings = SettingsStore();

  final _statusCtrl = StreamController<QuestStatusUpdate>.broadcast();
  final _transcriptCtrl = StreamController<TranscriptLine>.broadcast();

  Stream<QuestStatusUpdate> get statusStream => _statusCtrl.stream;
  Stream<TranscriptLine> get transcriptStream => _transcriptCtrl.stream;

  /// Останні події з фази очікування кодового слова — потрапляють у журнал
  /// наступної сесії як преамбула (що саме почув Vosk, який мікрофон обрано).
  final _preWake = <TranscriptLine>[];
  static const _preWakeMax = 15;

  bool _stopRequested = false;
  bool _running = false;
  int _runCount = 0;
  QuestTransport? _transport;
  // Дозволяє stop() завершити активний хід миттєво, а не чекати до 1с
  // наступного тіку сторожового таймера в _runOnce().
  void Function()? _abortCurrentRun;

  bool get isRunning => _running;

  /// ЄДИНИЙ шлях будь-якого рядка транскрипту/діагностики: час появи,
  /// екран і текстовий журнал сесії (або преамбула, якщо сесія ще не
  /// почалась). Контролери можуть бути вже закриті (екран пішов, а цикл ще
  /// дозавершується) — тоді рядок просто не показуємо.
  void _say(String who, String text) {
    final line = TranscriptLine(who, text);
    if (!_transcriptCtrl.isClosed) _transcriptCtrl.add(line);
    if (_logger.isActive) {
      _logger.log(line);
    } else {
      _preWake.add(line);
      if (_preWake.length > _preWakeMax) _preWake.removeAt(0);
    }
  }

  void _status(QuestStatusUpdate update) {
    if (!_statusCtrl.isClosed) _statusCtrl.add(update);
  }

  /// Запустити нескінченний цикл «сплю (чекаю кодове слово) → квест →
  /// перемога/тайм-аут → пауза → знову сплю». Повертається лише після
  /// виклику [stop].
  Future<void> run() async {
    if (_running) return;
    _running = true;
    _stopRequested = false;
    await audio.open();

    while (!_stopRequested) {
      await _refreshCharacter();
      _status(QuestStatusUpdate(QuestPhase.listening, runCount: _runCount));
      bool woke;
      try {
        woke = await wakeGate.waitForWake(
          wakeWords: character.effectiveWakeWords,
          isStopRequested: () => _stopRequested,
        );
      } catch (e) {
        _say('system', 'Розпізнавання кодового слова: $e');
        woke = false;
        if (!_stopRequested) {
          await Future<void>.delayed(
            Duration(milliseconds: (kRestartCooldownS * 1000).round()),
          );
        }
      }
      if (_stopRequested || !woke) {
        if (_stopRequested) break;
        continue; // помилка розпізнавання — спробувати слухати ще раз
      }

      _runCount++;
      _status(QuestStatusUpdate(QuestPhase.connecting, runCount: _runCount));
      final startedAt = DateTime.now();
      // Спільне ім'я для аудіо (.m4a) і журналу (.txt) цієї сесії.
      final baseName = newSessionBaseName();
      // Журнал і запис починаються тут — рівно в момент, коли Vosk почув
      // кодове слово, — а не пізніше (напр. лише після під'єднання до
      // транспорту), щоб у файлах лишався весь квест від самого початку.
      // Запис аудіо перемикається в налаштуваннях (увімкнено за
      // замовчуванням); журнал пишеться завжди.
      final recording = await _settings.getSessionRecordingEnabled();
      await _logger.start(
        baseName,
        header: await _logHeader(startedAt, recording ? '$baseName.m4a' : null),
        preamble: List<TranscriptLine>.from(_preWake),
      );
      _preWake.clear();
      _say('system', 'Журнал сесії: ${_logger.location}');
      if (recording) {
        await _recorder.start(baseName);
        _say('system', 'Запис сесії: ${_recorder.currentPath}');
      }
      final outcome = await _runOnce();
      await _recorder.stop();
      if (recording) {
        // Читаємо лічильники ПІСЛЯ stop() — вона чекає на спорожнення
        // черги запису, інакше останні ще не оброблені шматки не
        // потрапили б у цю діагностику.
        final micS = _recorder.lastMicSeconds.toStringAsFixed(1);
        final agentS = _recorder.lastAgentSeconds.toStringAsFixed(1);
        final peak = (_recorder.lastMicPeak * 100).toStringAsFixed(0);
        final err = _recorder.lastError;
        _say(
          'system',
          // ignore: unnecessary_brace_in_string_interps
          'Запис: голос дитини ${micS}с (гучність $peak%), '
          // ignore: unnecessary_brace_in_string_interps
          'голос персонажа ${agentS}с.${err == null ? '' : ' Помилка: $err'}',
        );
      }
      final durationS = DateTime.now().difference(startedAt).inSeconds;
      // Знімок пам'яті наприкінці КОЖНОЇ спроби: якщо цифри процесу ростуть
      // від спроби до спроби — це витік, і журнали покажуть його раніше, ніж
      // система вб'є застосунок через LOW_MEMORY.
      final memory = await DeviceMemory.describe();
      if (memory != null) _say('system', "Пам'ять: $memory");
      _say(
        'system',
        'Підсумок спроби №$_runCount: ${_outcomeLabel(outcome)}, '
        'тривалість ${durationS ~/ 60} хв ${durationS % 60} с.',
      );
      await _logger.stop();
      if (_stopRequested) break;
      _status(
        QuestStatusUpdate(
          QuestPhase.restarting,
          lastOutcome: outcome,
          runCount: _runCount,
        ),
      );
      await Future<void>.delayed(
        Duration(milliseconds: (kRestartCooldownS * 1000).round()),
      );
    }

    await audio.dispose();
    await wakeGate.dispose();
    _status(QuestStatusUpdate(QuestPhase.stopped, runCount: _runCount));
    _running = false;
  }

  /// Службова шапка журналу сесії — усе, що знадобиться при розборі
  /// проблеми без доступу до самого телефона.
  Future<List<String>> _logHeader(DateTime startedAt, String? audioName) async {
    String two(int n) => n.toString().padLeft(2, '0');
    final d = startedAt;
    final voice = character.provider == 'google'
        ? character.voice
        : character.openaiVoice;
    return [
      'Оствиця — журнал сесії квесту',
      'Початок: ${d.year}-${two(d.month)}-${two(d.day)} '
          '${two(d.hour)}:${two(d.minute)}:${two(d.second)}',
      'Персонаж: ${character.displayName} (${character.id}), '
          'провайдер ${character.provider}, голос $voice',
      'Кодове слово: ${character.effectiveWakeWords.join(', ')} · '
          'слово перемоги: ${character.winWord}',
      'Спроба №$_runCount',
      'Термінал: ${await _settings.getInstanceId()}',
      'Версія застосунку: ${kAppVersion.isEmpty ? '—' : kAppVersion}',
      'Запис аудіо: ${audioName ?? 'вимкнено в налаштуваннях'}',
      "Пам'ять на старті: ${await DeviceMemory.describe() ?? '—'}",
    ];
  }

  String _outcomeLabel(QuestOutcome outcome) {
    switch (outcome) {
      case QuestOutcome.won:
        return 'перемога';
      case QuestOutcome.timeout:
        return 'тайм-аут';
      case QuestOutcome.error:
        return 'помилка';
      case QuestOutcome.aborted:
        return 'зупинено вручну';
    }
  }

  /// Підхопити з диска новішу версію персонажа (її могла принести
  /// синхронізація з сервером), не перериваючи цикл. Лише МІЖ квестами:
  /// посеред живої розмови персонажа не підмінюємо. Провайдер і API-ключ
  /// обрані під час відкриття екрана — їх зміна підхопиться після
  /// перезаходу, а голос/промпт/кодові слова (те, що реально редагують)
  /// застосовуються тут.
  Future<void> _refreshCharacter() async {
    try {
      final fresh = await CharacterStore().read(character.id);
      if (fresh != null && fresh.updatedAt > character.updatedAt) {
        character = fresh;
        _say(
          'system',
          'Персонажа оновлено із синхронізації — застосовано нову версію.',
        );
      }
    } catch (_) {
      // Не вдалося перечитати — граємо з тим, що є.
    }
  }

  Future<void> stop() async {
    _stopRequested = true;
    _abortCurrentRun?.call();
    try {
      await _transport?.close();
    } catch (_) {}
  }

  Future<QuestOutcome> _runOnce() async {
    final winStemValue = winStem(character.winWord);
    final completer = Completer<QuestOutcome>();
    var userBuf = '';
    var modelBuf = '';
    var won = false;
    var lastVoice = DateTime.now();
    final startTime = DateTime.now();

    final transport = transportFactory(character, apiKey);
    _transport = transport;

    void finish(QuestOutcome outcome) {
      if (!completer.isCompleted) {
        completer.complete(outcome);
      }
    }

    _abortCurrentRun = () => finish(QuestOutcome.aborted);

    var loggedFirstAudioChunk = false;

    final eventsSub = transport.events.listen((evt) {
      switch (evt.kind) {
        case QuestEventKind.ready:
          _status(QuestStatusUpdate(QuestPhase.running, runCount: _runCount));
          _say('system', 'Плеєр голосу: ініціалізація...');
          audio
              .start(
                inputSampleRate: transport.inputSampleRate,
                outputSampleRate: transport.outputSampleRate,
                onMic: (chunk) {
                  unawaited(
                    _recorder.writeMic(chunk, transport.inputSampleRate),
                  );
                  transport.sendAudio(chunk);
                },
              )
              .then((_) {
                _say('system', 'Плеєр голосу: готовий.');
              })
              .catchError((Object e) {
                _say('system', 'Мікрофон: $e');
                finish(QuestOutcome.error);
              });
          break;
        case QuestEventKind.userTranscriptDelta:
          userBuf += evt.text ?? '';
          lastVoice = DateTime.now();
          break;
        case QuestEventKind.agentTranscriptDelta:
          modelBuf += evt.text ?? '';
          lastVoice = DateTime.now();
          if (!won &&
              winStemValue.isNotEmpty &&
              normalizeText(modelBuf).contains(winStemValue)) {
            won = true;
          }
          break;
        case QuestEventKind.turnComplete:
          if (!loggedFirstAudioChunk) {
            _say(
              'system',
              'Хід завершився без жодного шматка аудіо від Gemini.',
            );
          }
          if (userBuf.trim().isNotEmpty) {
            _say('user', userBuf.trim());
          }
          if (modelBuf.trim().isNotEmpty) {
            _say('agent', modelBuf.trim());
          }
          userBuf = '';
          modelBuf = '';
          audio.unmuteIfNoAudioYet();
          // Сесію НЕ закриваємо одразу після перемоги: даємо дітям
          // [kWinRepeatWindowS] секунд тиші, щоб встигнути перепитати таємне
          // слово (модель сама вирішує, чи повторити — див. інструкцію),
          // а завершує квест сторожовий таймер нижче.
          break;
        case QuestEventKind.interrupted:
          break;
        case QuestEventKind.info:
          _say('system', evt.text ?? '');
          break;
        case QuestEventKind.error:
          _say('system', evt.text ?? 'помилка');
          finish(QuestOutcome.error);
          break;
        case QuestEventKind.closed:
          // Раніше сесія, яку сервер закрив сам (напр. через недійсний
          // API-ключ), помирала БЕЗ ЖОДНОГО сліду в діагностиці — на екрані
          // просто йшов «Перезапуск квесту». Тому причину показуємо завжди.
          if (!_stopRequested) {
            _say(
              'system',
              evt.text == null
                  ? "Сервер закрив з'єднання без пояснення причини."
                  : "Сервер закрив з'єднання: ${evt.text}",
            );
          }
          finish(_stopRequested ? QuestOutcome.aborted : QuestOutcome.error);
          break;
      }
    });

    final audioSub = transport.outputAudio.listen((chunk) {
      lastVoice = DateTime.now();
      if (!loggedFirstAudioChunk) {
        loggedFirstAudioChunk = true;
        _say(
          'system',
          'Отримано перший шматок голосу персонажа (${chunk.length} байт).',
        );
      }
      unawaited(audio.playAgentChunk(chunk, transport.outputSampleRate));
      unawaited(_recorder.writeAgent(chunk, transport.outputSampleRate));
    });

    final watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_stopRequested) {
        finish(QuestOutcome.aborted);
        return;
      }
      final elapsedS = DateTime.now().difference(startTime).inSeconds;
      if (elapsedS >= kMaxDurationS) {
        finish(QuestOutcome.timeout);
        return;
      }
      final idleS = DateTime.now().difference(lastVoice).inSeconds;
      if (won) {
        // Коротше вікно тиші після перемоги — щоб не тримати сесію
        // відкритою цілу годину, поки ніхто вже не слухає.
        if (idleS > kWinRepeatWindowS) {
          finish(QuestOutcome.won);
        }
        return;
      }
      if (idleS > kInactivityTimeoutS) {
        finish(QuestOutcome.timeout);
      }
    });

    try {
      await transport.connect();
    } catch (e) {
      _say('system', "Не вдалося під'єднатися: $e");
      finish(QuestOutcome.error);
    }

    final outcome = await completer.future;
    _abortCurrentRun = null;

    watchdog.cancel();
    await eventsSub.cancel();
    await audioSub.cancel();
    await audio.stop();
    try {
      await transport.close();
    } catch (_) {}
    _transport = null;

    return outcome;
  }

  Future<void> dispose() async {
    await stop();
    await _statusCtrl.close();
    await _transcriptCtrl.close();
  }
}

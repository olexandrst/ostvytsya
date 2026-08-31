import 'dart:async';

import '../constants.dart';
import '../models/character.dart';
import '../services/character_store.dart';
import '../services/session_recorder.dart';
import '../services/settings_store.dart';
import 'audio_pipeline.dart';
import 'transcript_utils.dart';
import 'transport.dart';
import 'wake_gate.dart';

enum QuestPhase { listening, connecting, running, restarting, stopped }

enum QuestOutcome { won, timeout, error, aborted }

class QuestStatusUpdate {
  final QuestPhase phase;
  final QuestOutcome? lastOutcome;
  final int runCount;

  const QuestStatusUpdate(this.phase, {this.lastOutcome, this.runCount = 0});
}

class TranscriptLine {
  final String who; // 'user' | 'agent' | 'system'
  final String text;

  const TranscriptLine(this.who, this.text);
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
    wakeGate.diagnostics.listen((msg) {
      _transcriptCtrl.add(TranscriptLine('system', msg));
    });
    // Так само для вибору аудіо-пристрою під час самого квесту — щоб було
    // видно, чи автопідбір справді бачить і обирає зовнішній мікрофон.
    audio.diagnostics.listen((msg) {
      _transcriptCtrl.add(TranscriptLine('system', msg));
    });
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
  final SettingsStore _settings = SettingsStore();

  final _statusCtrl = StreamController<QuestStatusUpdate>.broadcast();
  final _transcriptCtrl = StreamController<TranscriptLine>.broadcast();

  Stream<QuestStatusUpdate> get statusStream => _statusCtrl.stream;
  Stream<TranscriptLine> get transcriptStream => _transcriptCtrl.stream;

  bool _stopRequested = false;
  bool _running = false;
  int _runCount = 0;
  QuestTransport? _transport;
  // Дозволяє stop() завершити активний хід миттєво, а не чекати до 1с
  // наступного тіку сторожового таймера в _runOnce().
  void Function()? _abortCurrentRun;

  bool get isRunning => _running;

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
      _statusCtrl.add(
        QuestStatusUpdate(QuestPhase.listening, runCount: _runCount),
      );
      bool woke;
      try {
        woke = await wakeGate.waitForWake(
          wakeWords: character.effectiveWakeWords,
          isStopRequested: () => _stopRequested,
        );
      } catch (e) {
        _transcriptCtrl.add(
          TranscriptLine('system', 'Розпізнавання кодового слова: $e'),
        );
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
      _statusCtrl.add(
        QuestStatusUpdate(QuestPhase.connecting, runCount: _runCount),
      );
      // Запис починається тут — рівно в момент, коли Vosk почув кодове
      // слово, — а не пізніше (напр. лише після під'єднання до транспорту),
      // щоб у файлі лишався весь квест від самого початку. Перемикається в
      // налаштуваннях (увімкнено за замовчуванням).
      final recording = await _settings.getSessionRecordingEnabled();
      if (recording) {
        await _recorder.start();
        _transcriptCtrl.add(
          TranscriptLine('system', 'Запис сесії: ${_recorder.currentPath}'),
        );
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
        _transcriptCtrl.add(
          TranscriptLine(
            'system',
            // ignore: unnecessary_brace_in_string_interps
            'Запис: голос дитини ${micS}с (гучність $peak%), '
            // ignore: unnecessary_brace_in_string_interps
            'голос персонажа ${agentS}с.${err == null ? '' : ' Помилка: $err'}',
          ),
        );
      }
      if (_stopRequested) break;
      _statusCtrl.add(
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
    _statusCtrl.add(QuestStatusUpdate(QuestPhase.stopped, runCount: _runCount));
    _running = false;
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
        _transcriptCtrl.add(
          const TranscriptLine(
            'system',
            'Персонажа оновлено із синхронізації — застосовано нову версію.',
          ),
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
          _statusCtrl.add(
            QuestStatusUpdate(QuestPhase.running, runCount: _runCount),
          );
          _transcriptCtrl.add(
            const TranscriptLine('system', 'Плеєр голосу: ініціалізація...'),
          );
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
                _transcriptCtrl.add(
                  const TranscriptLine('system', 'Плеєр голосу: готовий.'),
                );
              })
              .catchError((Object e) {
                _transcriptCtrl.add(TranscriptLine('system', 'Мікрофон: $e'));
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
            _transcriptCtrl.add(
              const TranscriptLine(
                'system',
                'Хід завершився без жодного шматка аудіо від Gemini.',
              ),
            );
          }
          if (userBuf.trim().isNotEmpty) {
            _transcriptCtrl.add(TranscriptLine('user', userBuf.trim()));
          }
          if (modelBuf.trim().isNotEmpty) {
            _transcriptCtrl.add(TranscriptLine('agent', modelBuf.trim()));
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
        case QuestEventKind.error:
          _transcriptCtrl.add(TranscriptLine('system', evt.text ?? 'помилка'));
          finish(QuestOutcome.error);
          break;
        case QuestEventKind.closed:
          // Раніше сесія, яку сервер закрив сам (напр. через недійсний
          // API-ключ), помирала БЕЗ ЖОДНОГО сліду в діагностиці — на екрані
          // просто йшов «Перезапуск квесту». Тому причину показуємо завжди.
          if (!_stopRequested) {
            _transcriptCtrl.add(
              TranscriptLine(
                'system',
                evt.text == null
                    ? "Сервер закрив з'єднання без пояснення причини."
                    : "Сервер закрив з'єднання: ${evt.text}",
              ),
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
        _transcriptCtrl.add(
          TranscriptLine(
            'system',
            'Отримано перший шматок голосу персонажа (${chunk.length} байт).',
          ),
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
      _transcriptCtrl.add(
        TranscriptLine('system', "Не вдалося під'єднатися: $e"),
      );
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

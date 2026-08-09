import 'dart:async';

import '../constants.dart';
import '../models/character.dart';
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
  }

  final Character character;
  final String apiKey;
  final QuestTransportFactory transportFactory;
  final AudioPipeline audio = AudioPipeline();
  final WakeGateService wakeGate = WakeGateService();

  final _statusCtrl = StreamController<QuestStatusUpdate>.broadcast();
  final _transcriptCtrl = StreamController<TranscriptLine>.broadcast();

  Stream<QuestStatusUpdate> get statusStream => _statusCtrl.stream;
  Stream<TranscriptLine> get transcriptStream => _transcriptCtrl.stream;

  bool _stopRequested = false;
  bool _running = false;
  int _runCount = 0;
  QuestTransport? _transport;

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
      final outcome = await _runOnce();
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

  Future<void> stop() async {
    _stopRequested = true;
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

    final eventsSub = transport.events.listen((evt) {
      switch (evt.kind) {
        case QuestEventKind.ready:
          _statusCtrl.add(
            QuestStatusUpdate(QuestPhase.running, runCount: _runCount),
          );
          audio
              .start(
                inputSampleRate: transport.inputSampleRate,
                outputSampleRate: transport.outputSampleRate,
                onMic: transport.sendAudio,
              )
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
          if (userBuf.trim().isNotEmpty) {
            _transcriptCtrl.add(TranscriptLine('user', userBuf.trim()));
          }
          if (modelBuf.trim().isNotEmpty) {
            _transcriptCtrl.add(TranscriptLine('agent', modelBuf.trim()));
          }
          userBuf = '';
          modelBuf = '';
          if (won) {
            audio.waitDrained().then((_) => finish(QuestOutcome.won));
          }
          break;
        case QuestEventKind.interrupted:
          break;
        case QuestEventKind.error:
          _transcriptCtrl.add(TranscriptLine('system', evt.text ?? 'помилка'));
          finish(QuestOutcome.error);
          break;
        case QuestEventKind.closed:
          finish(_stopRequested ? QuestOutcome.aborted : QuestOutcome.error);
          break;
      }
    });

    final audioSub = transport.outputAudio.listen((chunk) {
      lastVoice = DateTime.now();
      unawaited(audio.playAgentChunk(chunk, transport.outputSampleRate));
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
      if (won) return;
      final idleS = DateTime.now().difference(lastVoice).inSeconds;
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

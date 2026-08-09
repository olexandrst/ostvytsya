import 'dart:async';
import 'dart:convert';

import 'package:record/record.dart';
import 'package:vosk_flutter_service/vosk_flutter_service.dart';

import '../constants.dart';
import 'wake_matcher.dart';

/// Локальне (офлайн, без мережі) очікування кодового слова персонажа —
/// порт domovyk_quest/wake/vosk_wake.py. Квест і сесія Gemini/OpenAI НЕ
/// стартують, поки [waitForWake] не поверне true.
///
/// Модель Vosk (українська, "nano") на диску телефону не бере жодного місця
/// в APK — вона качається й кешується один раз при першому використанні
/// (ModelLoader.loadFromNetwork сам перевіряє, чи вже завантажена).
///
/// Мікрофон тут — ОКРЕМИЙ інстанс `record`, незалежний від AudioPipeline
/// (котра керує мікрофоном під час самого квесту). Ніколи не працюють
/// одночасно: [waitForWake] завжди повністю зупиняє свій запис перед тим,
/// як повернути результат.
class WakeGateService {
  static const sampleRate = 16000;
  static const _fuzzyThreshold = 0.70;

  /// Скільки послідовних помилок розпізнавання поспіль допустимо, перш ніж
  /// вважати мікрофон/розпізнавач непрацездатним і повідомити про помилку,
  /// а не мовчки "слухати" вічно без жодного результату.
  static const _maxConsecutiveErrors = 50;

  final AudioRecorder _recorder = AudioRecorder();
  Recognizer? _recognizer;
  Future<void>? _readyFuture;

  final _diagCtrl = StreamController<String>.broadcast();

  /// Людяні діагностичні повідомлення: стан завантаження моделі, що саме
  /// почув мікрофон (частковий текст), помилки розпізнавання. Призначено
  /// для показу в транскрипті квесту, щоб було видно, що насправді
  /// відбувається, поки персонаж "спить".
  Stream<String> get diagnostics => _diagCtrl.stream;

  /// Завантажити модель і створити розпізнавач (один раз за весь час
  /// роботи застосунку — повторні виклики просто чекають той самий Future).
  Future<void> ensureReady() {
    return _readyFuture ??= _load();
  }

  Future<void> _load() async {
    _diagCtrl.add('Завантажую модель Vosk (один раз, потім кешується)...');
    try {
      final vosk = VoskFlutterPlugin.instance();
      final modelPath = await ModelLoader().loadFromNetwork(kVoskModelUrl);
      final model = await vosk.createModel(modelPath);
      _recognizer = await vosk.createRecognizer(
        model: model,
        sampleRate: sampleRate,
      );
      _diagCtrl.add('Модель Vosk готова, слухаю мікрофон.');
    } catch (e) {
      _diagCtrl.add('Не вдалося завантажити модель Vosk: $e');
      rethrow;
    }
  }

  /// Слухати мікрофон локально, доки не почується одне з [wakeWords], або
  /// доки [isStopRequested] не почне повертати true (користувач натиснув
  /// «Зупинити»). Повертає true лише якщо почуто кодове слово.
  Future<bool> waitForWake({
    required List<String> wakeWords,
    required bool Function() isStopRequested,
  }) async {
    await ensureReady();
    final recognizer = _recognizer!;
    await recognizer.reset();

    final completer = Completer<bool>();
    void finish(bool value) {
      if (!completer.isCompleted) completer.complete(value);
    }

    final stream = await _recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
      ),
    );

    final stopTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (isStopRequested()) finish(false);
    });

    var consecutiveErrors = 0;
    var lastPartial = '';

    final sub = stream.listen((chunk) async {
      if (completer.isCompleted) return;
      try {
        final ready = await recognizer.acceptWaveformBytes(chunk);
        final raw = ready
            ? await recognizer.getResult()
            : await recognizer.getPartialResult();
        final text = _extractText(raw, ready);
        consecutiveErrors = 0;
        if (text.isNotEmpty && text != lastPartial) {
          lastPartial = text;
          _diagCtrl.add('Чую: «$text»');
        }
        if (text.isNotEmpty &&
            matchesWakeWord(text, wakeWords, threshold: _fuzzyThreshold)) {
          finish(true);
        }
      } catch (e) {
        consecutiveErrors++;
        if (consecutiveErrors == 1 || consecutiveErrors % 20 == 0) {
          _diagCtrl.add('Помилка розпізнавання (×$consecutiveErrors): $e');
        }
        if (consecutiveErrors >= _maxConsecutiveErrors &&
            !completer.isCompleted) {
          completer.completeError(
            Exception('Розпізнавання постійно падає: $e'),
          );
        }
      }
    });

    try {
      final result = await completer.future;
      return result;
    } finally {
      stopTimer.cancel();
      await sub.cancel();
      try {
        await _recorder.stop();
      } catch (_) {}
    }
  }

  String _extractText(String rawJson, bool isFinal) {
    try {
      final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
      final key = isFinal ? 'text' : 'partial';
      return (decoded[key] as String?)?.trim() ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> dispose() async {
    try {
      await _recorder.dispose();
    } catch (_) {}
    try {
      await _recognizer?.dispose();
    } catch (_) {}
    await _diagCtrl.close();
  }
}

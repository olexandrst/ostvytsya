import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:vosk_flutter_service/vosk_flutter_service.dart';

import '../constants.dart';
import '../services/audio_device_service.dart';
import '../services/settings_store.dart';
import 'wake_matcher.dart';

/// Локальне (офлайн, без мережі) очікування кодового слова персонажа —
/// порт domovyk_quest/wake/vosk_wake.py. Квест і сесія Gemini/OpenAI НЕ
/// стартують, поки [waitForWake] не поверне true.
///
/// Модель Vosk на диску телефону не бере жодного місця в APK — вона качається
/// й кешується один раз при першому використанні (ModelLoader.loadFromNetwork
/// сам перевіряє, чи вже завантажена).
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

  /// Скільки після активації SCO не реагувати на зміни списку пристроїв:
  /// підняття голосового каналу саме по собі перебудовує цей список
  /// (гарнітура зникає й повертається вже як SCO-вхід), і без цієї паузи
  /// автопідбір встигав перестрибнути назад на вбудований мікрофон.
  static const _scoSettleGuard = Duration(seconds: 5);

  final AudioRecorder _recorder = AudioRecorder();
  final AudioDeviceService _deviceService = AudioDeviceService();
  final SettingsStore _settings = SettingsStore();
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

  Future<AudioDevice?> _resolveInputDevice() async {
    try {
      final devices = await _deviceService.listInputDevices();
      final preferred = await _settings.getPreferredInputDeviceId();
      return AudioDeviceService.resolve(devices, preferred);
    } catch (_) {
      return null;
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

    StreamSubscription<Uint8List>? sub;
    var consecutiveErrors = 0;
    var lastPartial = '';
    var currentDevice = await _resolveInputDevice();
    var scoActive = false;
    // Доки SCO піднімається, список аудіо-пристроїв «мигтить» — це наслідок
    // НАШОЇ ж активації: гарнітура на мить зникає зі списку входів, а потім
    // повертається вже як SCO-пристрій (кількість входів росте). Доти
    // ігноруємо зміни пристроїв, інакше автопідбір встигає перестрибнути на
    // вбудований мікрофон і зірвати щойно початкове встановлення SCO.
    var scoSettlingUntil = DateTime.fromMillisecondsSinceEpoch(0);

    Future<void> startStream() async {
      var device = currentDevice;
      // Раніше тут не було видно взагалі нічого про вибір мікрофона — при
      // мовчазній тиші неможливо було відрізнити «слухаю не той пристрій»
      // від «розпізнавання не працює».
      _diagCtrl.add(
        device == null
            ? 'Слухаю мікрофон за замовчуванням.'
            : 'Слухаю мікрофон «${device.label}».',
      );
      // Мікрофон Bluetooth-гарнітури мовчить, доки не піднято SCO.
      if (device != null && device.bucket == 'bluetooth') {
        if (!scoActive) {
          scoSettlingUntil = DateTime.now().add(_scoSettleGuard);
          final ok = await _deviceService.startBluetoothMic(device.id);
          scoActive = ok;
          _diagCtrl.add(
            ok
                ? 'Bluetooth-мікрофон: вмикаю голосовий канал (SCO)...'
                : 'Bluetooth-мікрофон: не вдалося увімкнути голосовий канал.',
          );
          if (ok) {
            await Future<void>.delayed(AudioDeviceService.scoSettleDelay);
            // Коли SCO піднявся, гарнітура зазвичай з'являється у списку
            // ЗАНОВО — з іншим id. Прив'язка до старого id дала б знову
            // тишу, тож перечитуємо й беремо актуальний bluetooth-вхід.
            final refreshed = await _resolveInputDevice();
            if (refreshed != null && refreshed.bucket == 'bluetooth') {
              device = refreshed;
              currentDevice = refreshed;
              _diagCtrl.add('Bluetooth-мікрофон: готовий («${device.label}»).');
            }
            scoSettlingUntil = DateTime.now().add(_scoSettleGuard);
          }
        }
      } else if (scoActive) {
        await _deviceService.stopBluetoothMic();
        scoActive = false;
      }
      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
          device: device == null
              ? null
              : InputDevice(id: device.id, label: device.label),
        ),
      );
      sub = stream.listen((chunk) async {
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
    }

    await startStream();

    // Поки чекаємо кодове слово (могло бути й довго), реагуємо на
    // під'єднання/від'єднання пристроїв: якщо найкращий доступний мікрофон
    // змінився — перезапускаємо потік на новому, не гублячи сам факт
    // очікування (квест і так ще не почався).
    final deviceChangeSub = AudioDeviceService.onDevicesChanged.listen((
      _,
    ) async {
      if (completer.isCompleted) return;
      // Мигтіння списку, спричинене нашою ж активацією SCO, — не привід
      // перевибирати мікрофон.
      if (DateTime.now().isBefore(scoSettlingUntil)) return;
      final newDevice = await _resolveInputDevice();
      if (newDevice?.id == currentDevice?.id) return;
      // Свідомо НЕ «прилипаємо» до гарнітури назавжди: після паузи вище
      // зникнення bluetooth зі списку означає справжнє від'єднання, і тоді
      // треба чесно перейти на вбудований мікрофон (startStream сама зніме
      // SCO). Інакше від'єднана гарнітура залишила б квест глухим.
      currentDevice = newDevice;
      await sub?.cancel();
      try {
        await _recorder.stop();
      } catch (_) {}
      if (!completer.isCompleted) await startStream();
    });

    final stopTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (isStopRequested()) finish(false);
    });

    try {
      final result = await completer.future;
      return result;
    } finally {
      stopTimer.cancel();
      await deviceChangeSub.cancel();
      await sub?.cancel();
      try {
        await _recorder.stop();
      } catch (_) {}
      // Далі квест сам підніме SCO, якщо він йому потрібен, — тут маршрут
      // лишати за собою не можна.
      await _deviceService.stopBluetoothMic();
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

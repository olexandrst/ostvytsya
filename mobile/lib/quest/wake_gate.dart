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

  final AudioRecorder _recorder = AudioRecorder();
  final AudioDeviceService _deviceService = AudioDeviceService();
  final SettingsStore _settings = SettingsStore();
  Recognizer? _recognizer;

  /// Модель і розпізнавач Vosk — ОДНІ НА ВЕСЬ ПРОЦЕС, а не на екземпляр.
  ///
  /// ‼️ Це не оптимізація, а виправлення витоку, що вбивало застосунок
  /// (LOW_MEMORY від системи прямо посеред квесту на Galaxy A27). На Android
  /// плагін vosk_flutter_service на кожен createModel() створює НОВИЙ
  /// org.vosk.Model (сотні МБ нативної пам'яті) і кладе його в мапу за
  /// шляхом, НЕ закриваючи попередній; Model.dispose() на Android — порожній,
  /// а моделі звільняються лише при від'єднанні Flutter-двигуна. Раніше
  /// WakeGateService створювався на кожне відкриття екрана квесту й щоразу
  /// підвантажував модель заново — тож кожен новий квест додавав у пам'ять
  /// ще одну повну копію моделі, доки система не вбивала процес.
  static Future<Recognizer>? _sharedRecognizer;

  final _diagCtrl = StreamController<String>.broadcast();

  /// Людяні діагностичні повідомлення: стан завантаження моделі, що саме
  /// почув мікрофон (частковий текст), помилки розпізнавання. Призначено
  /// для показу в транскрипті квесту, щоб було видно, що насправді
  /// відбувається, поки персонаж "спить".
  Stream<String> get diagnostics => _diagCtrl.stream;

  /// Підхопити спільний розпізнавач (модель завантажується один раз за
  /// весь час роботи застосунку — далі всі екземпляри чекають той самий
  /// Future і отримують той самий об'єкт).
  Future<void> ensureReady() async {
    final existing = _sharedRecognizer;
    if (existing != null) {
      _recognizer = await existing;
      return;
    }
    _diagCtrl.add('Завантажую модель Vosk (один раз за запуск застосунку)...');
    final loading = _loadShared();
    _sharedRecognizer = loading;
    try {
      _recognizer = await loading;
      _diagCtrl.add('Модель Vosk готова, слухаю мікрофон.');
    } catch (e) {
      // Невдале завантаження не «заморожуємо» назавжди — наступна спроба
      // піде знову (напр. після того, як модель докачається).
      _sharedRecognizer = null;
      _diagCtrl.add('Не вдалося завантажити модель Vosk: $e');
      rethrow;
    }
  }

  static Future<Recognizer> _loadShared() async {
    final vosk = VoskFlutterPlugin.instance();
    final modelPath = await ModelLoader().loadFromNetwork(kVoskModelUrl);
    final model = await vosk.createModel(modelPath);
    return vosk.createRecognizer(model: model, sampleRate: sampleRate);
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
    var lastFinalAt = DateTime.now();
    var currentDevice = await _resolveInputDevice();

    Future<void> startStream() async {
      final device = currentDevice;
      // Раніше тут не було видно взагалі нічого про вибір мікрофона — при
      // мовчазній тиші неможливо було відрізнити «слухаю не той пристрій»
      // від «розпізнавання не працює».
      _diagCtrl.add(
        device == null
            ? 'Слухаю мікрофон за замовчуванням.'
            : 'Слухаю мікрофон «${device.label}».',
      );
      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: sampleRate,
          numChannels: 1,
          // ‼️ Для Bluetooth НЕ називаємо конкретний пристрій. Плагін
          // `record` вимикає власне керування SCO, якщо переданий пристрій
          // має тип, відмінний від TYPE_BLUETOOTH_SCO — а та сама гарнітура
          // присутня у списку і як BLE/A2DP, тож ми легко передавали «не
          // ту» її іпостась. У такому разі плагін не просто не піднімає
          // канал, а РВЕ вже піднятий — і мікрофон гарнітури віддає тишу.
          // З null плагін сам піднімає SCO, ЧЕКАЄ на підтвердження
          // з'єднання і лише тоді починає запис, а Android скеровує
          // захоплення саме з гарнітури.
          device: (device == null || device.bucket == 'bluetooth')
              ? null
              : InputDevice(id: device.id, label: device.label),
          androidConfig: const AndroidRecordConfig(manageBluetooth: true),
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
            return;
          }
          if (ready) {
            lastFinalAt = DateTime.now();
          } else if (_needsReset(text, lastFinalAt)) {
            // Термінал слухає ГОДИНАМИ. У шумі парку (вітер, гурт дітей)
            // розпізнавач може довго не бачити кінця фрази й тягнути одне
            // нескінченне висловлювання — його внутрішній стан і час
            // обробки кожного шматка ростуть без меж. Скидаємо його
            // примусово: кодове слово й так шукаємо лише в останніх словах,
            // а те, що вже перевірили вище, втратити не страшно.
            await recognizer.reset();
            lastFinalAt = DateTime.now();
            lastPartial = '';
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
      final newDevice = await _resolveInputDevice();
      // Поки гарнітура на місці, лишаємось на ній: підняття SCO самим
      // плагіном перебудовує список входів, і без цієї умови автопідбір
      // устигав перескочити на вбудований мікрофон. Якщо ж bluetooth зник
      // зі списку зовсім — гарнітуру справді від'єднали, і перехід на
      // вбудований мікрофон правильний.
      if (newDevice?.id == currentDevice?.id) return;
      if (currentDevice?.bucket == 'bluetooth' &&
          newDevice?.bucket != 'bluetooth') {
        final stillThere = AudioDeviceService.firstBluetooth(
          await _deviceService.listInputDevices(),
        );
        if (stillThere != null) return;
      }
      currentDevice = newDevice;
      await sub?.cancel();
      try {
        await _recorder.stop();
      } catch (_) {}
      if (completer.isCompleted) return;
      try {
        await startStream();
      } catch (e) {
        // Раніше збій тут лишав очікування без мікрофона НАЗАВЖДИ (виняток
        // в асинхронному слухачі нікуди не потрапляв). Віддаємо помилку
        // контролеру — він перезапустить слухання після паузи.
        _diagCtrl.add('Не вдалося перезапустити мікрофон: $e');
        if (!completer.isCompleted) {
          completer.completeError(
            Exception('Мікрофон після зміни пристрою: $e'),
          );
        }
      }
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
    }
  }

  /// Скільки без жодного «кінця фрази» від розпізнавача терпимо, перш ніж
  /// скинути його (див. коментар у слухачі). Кодове слово вимовляється за
  /// 1–2 с, тож 20 с — із великим запасом.
  static const _maxUtterance = Duration(seconds: 20);

  /// Аналогічна стеля за довжиною часткового тексту.
  static const _maxPartialWords = 40;

  static bool _needsReset(String partial, DateTime lastFinalAt) {
    if (DateTime.now().difference(lastFinalAt) > _maxUtterance) return true;
    return partial.split(RegExp(r'\s+')).length > _maxPartialWords;
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

  /// Розпізнавач НЕ звільняємо — він спільний і живе до кінця процесу
  /// (див. _sharedRecognizer); reset() на початку кожного waitForWake
  /// прибирає його стан.
  Future<void> dispose() async {
    try {
      await _recorder.dispose();
    } catch (_) {}
    _recognizer = null;
    await _diagCtrl.close();
  }
}

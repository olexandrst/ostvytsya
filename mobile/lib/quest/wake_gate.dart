import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
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
///
/// Bluetooth-мікрофон (гарнітура/спікерфон, напр. Jabra Speak2): голосовий
/// канал (SCO) піднімає САМ застосунок — той самий CommunicationRouter, що
/// тримає канал під час квесту, — а не плагін `record`. Плагін лишається
/// запасним варіантом: якщо наш канал не піднявся або перевірка маршруту
/// показала, що запис іде не з гарнітури, слухання перезапускається з
/// керуванням каналом від плагіна. Що б не сталося — у журналі видно, з
/// якого пристрою насправді йде запис і який рівень сигналу.
class WakeGateService {
  static const sampleRate = 16000;

  /// Скільки послідовних помилок розпізнавання поспіль допустимо, перш ніж
  /// вважати мікрофон/розпізнавач непрацездатним і повідомити про помилку,
  /// а не мовчки "слухати" вічно без жодного результату.
  static const _maxConsecutiveErrors = 50;

  /// Через скільки після старту запису перевіряти справжній маршрут: за цей
  /// час гарнітура встигає підняти канал, а система — застосувати його.
  static const _routeCheckDelay = Duration(milliseconds: 2500);

  /// Як часто писати в журнал рівень сигналу мікрофона.
  static const _levelReportEvery = Duration(seconds: 15);

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

  /// Слухати мікрофон локально, доки не почується одне з [wakeWords] (або,
  /// якщо [wakeOnVoice], будь-яке розбірливе мовлення — для зазивайла біля
  /// входу), або доки [isStopRequested] не почне повертати true (користувач
  /// натиснув «Зупинити»). Повертає true лише якщо є привід прокинутись.
  Future<bool> waitForWake({
    required List<String> wakeWords,
    bool wakeOnVoice = false,
    required bool Function() isStopRequested,
  }) async {
    await ensureReady();
    final recognizer = _recognizer!;
    await recognizer.reset();

    // Поріг нечіткого збігу — з налаштувань (Налаштування → Кодове слово):
    // точний збіг спрацьовує завжди, поріг стосується спотворених варіантів.
    // Перечитуємо на кожне очікування, щоб зміна діяла без перезапуску.
    final thresholdPercent = await _settings.getWakeThresholdPercent();
    final fuzzyThreshold = thresholdPercent / 100.0;
    _diagCtrl.add(
      'Поріг збігу кодового слова: $thresholdPercent %'
      '${thresholdPercent == kDefaultWakeThresholdPercent ? ' (типово)' : ''}.',
    );

    final completer = Completer<bool>();
    void finish(bool value) {
      if (!completer.isCompleted) completer.complete(value);
    }

    StreamSubscription<Uint8List>? sub;
    var consecutiveErrors = 0;
    var lastPartial = '';
    var lastFinalAt = DateTime.now();
    var currentDevice = await _resolveInputDevice();

    // Покоління потоку запису: перевірка маршруту, що спізнилась до вже
    // перезапущеного потоку, не має нічого робити.
    var streamGen = 0;
    // Наш голосовий канал Bluetooth зараз піднято (треба зняти при зупинці).
    var scoOwned = false;
    // Власний канал не спрацював (запис ішов не з гарнітури) — далі канал
    // піднімає плагін запису, як це було до цієї зміни.
    var pluginScoFallback = false;
    final meter = _LevelMeter();
    late Future<void> Function(int gen, bool wantBluetooth, bool ownSco)
    verifyRoute;

    Future<void> startStream() async {
      final gen = ++streamGen;
      final device = currentDevice;
      final wantBluetooth = device?.bucket == 'bluetooth';
      var ownSco = false;
      if (wantBluetooth && !pluginScoFallback) {
        // Один господар каналу на весь застосунок (CommunicationRouter):
        // під час квесту канал і так тримаємо ми, тож і в очікуванні
        // кодового слова піднімаємо його самі, а не довіряємо плагіну.
        ownSco = await _deviceService.startSco();
        _diagCtrl.add(
          ownSco
              ? 'Bluetooth-мікрофон: голосовий канал підняв застосунок.'
              : 'Bluetooth-мікрофон: застосунок не зміг підняти голосовий '
                    'канал — доручаю його плагіну запису.',
        );
        if (ownSco) {
          await Future<void>.delayed(AudioDeviceService.scoSettleDelay);
        }
      }
      scoOwned = ownSco;
      // Раніше тут не було видно взагалі нічого про вибір мікрофона — при
      // мовчазній тиші неможливо було відрізнити «слухаю не той пристрій»
      // від «розпізнавання не працює».
      _diagCtrl.add(
        device == null
            ? 'Слухаю мікрофон за замовчуванням.'
            : 'Слухаю мікрофон «${device.label}»'
                  '${wantBluetooth ? (ownSco ? ' (канал наш)' : ' (канал від плагіна)') : ''}.',
      );
      if (wakeOnVoice) {
        _diagCtrl.add('Прокидаюсь від будь-якого голосу — без кодового слова.');
      }
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
          // З null система скеровує захоплення за активним каналом.
          device: (device == null || wantBluetooth)
              ? null
              : InputDevice(id: device.id, label: device.label),
          androidConfig: AndroidRecordConfig(
            // Канал тримаємо ми — плагін до нього не торкається. Лише як
            // запасний варіант (наш канал не піднявся) — керує плагін, як
            // було раніше.
            manageBluetooth: wantBluetooth && !ownSco,
            // Із нашим каналом запис має бути «клієнтом розмови»
            // (VOICE_COMMUNICATION) — саме такі клієнти система скеровує на
            // пристрій розмови (setCommunicationDevice); так само працює
            // мікрофон під час квесту.
            audioSource: ownSco
                ? AndroidAudioSource.voiceCommunication
                : AndroidAudioSource.defaultSource,
          ),
        ),
      );
      sub = stream.listen((chunk) async {
        if (completer.isCompleted) return;
        meter.add(chunk);
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
              matchesWakeWord(text, wakeWords, threshold: fuzzyThreshold)) {
            finish(true);
            return;
          }
          if (wakeOnVoice && _soundsLikeSpeech(text)) {
            _diagCtrl.add('Чую голоси — прокидаюсь.');
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
      unawaited(verifyRoute(gen, wantBluetooth, ownSco));
    }

    /// Зупинити поточний потік (і наш канал, якщо піднімали) і запустити
    /// заново з поточним [currentDevice] / стратегією каналу.
    Future<void> restartStream() async {
      await sub?.cancel();
      sub = null;
      try {
        await _recorder.stop();
      } catch (_) {}
      if (scoOwned) {
        scoOwned = false;
        await _deviceService.stopSco();
      }
      if (completer.isCompleted) return;
      try {
        await startStream();
      } catch (e) {
        // Раніше збій тут лишав очікування без мікрофона НАЗАВЖДИ (виняток
        // в асинхронному слухачі нікуди не потрапляв). Віддаємо помилку
        // контролеру — він перезапустить слухання після паузи.
        _diagCtrl.add('Не вдалося перезапустити мікрофон: $e');
        if (!completer.isCompleted) {
          completer.completeError(Exception('Мікрофон після перезапуску: $e'));
        }
      }
    }

    // Через кілька секунд після старту — що система робить НАСПРАВДІ: з
    // якого пристрою пише AudioRecord. Обрано Bluetooth, а запис іде з
    // телефона — канал не піднявся: один раз перезапускаємо слухання, щоб
    // канал підняв плагін (стара поведінка); не допомогло — пишемо в журнал
    // прямим текстом, що кодове слово слухає не той мікрофон.
    verifyRoute = (gen, wantBluetooth, ownSco) async {
      await Future<void>.delayed(_routeCheckDelay);
      if (completer.isCompleted || gen != streamGen) return;
      final state = await _deviceService.routeState();
      if (state == null || completer.isCompleted || gen != streamGen) return;
      _diagCtrl.add('Маршрут звуку: ${state.describe(sampleRate: sampleRate)}');
      if (!wantBluetooth) return;
      final rec = state.recordingAt(sampleRate);
      final actualBucket = rec?.bucket;
      if (rec == null || actualBucket == null || actualBucket == 'bluetooth') {
        return;
      }
      final from = rec.device ?? 'невідомого пристрою';
      if (ownSco && !pluginScoFallback) {
        pluginScoFallback = true;
        _diagCtrl.add(
          '⚠️ Обрано Bluetooth-мікрофон, а запис іде з «$from» — '
          'перезапускаю слухання, канал підніме плагін запису.',
        );
        await restartStream();
      } else {
        _diagCtrl.add(
          '⚠️ Обрано Bluetooth-мікрофон «${currentDevice?.label ?? 'Bluetooth'}», '
          'а запис іде з «$from»: голосовий канал не піднявся — кодове слово '
          'слухає НЕ той мікрофон. Перевір Bluetooth-з\'єднання гарнітури '
          '(профіль «Дзвінки») і дозвіл «Пристрої поблизу».',
        );
      }
    };

    try {
      await startStream();
    } catch (_) {
      // Мікрофон не стартував — не лишаємо піднятий канал гарнітури.
      if (scoOwned) {
        scoOwned = false;
        await _deviceService.stopSco();
      }
      rethrow;
    }

    // Рівень сигналу — щоб у журналі було видно, чи мікрофон узагалі щось
    // чує, коли діти говорять (тиша = не той мікрофон або він вимкнений).
    final levelTimer = Timer.periodic(_levelReportEvery, (_) {
      if (completer.isCompleted) return;
      _diagCtrl.add(
        'Мікрофон за ${_levelReportEvery.inSeconds} с: ${meter.reportAndReset()}',
      );
    });

    // Поки чекаємо кодове слово (могло бути й довго), реагуємо на
    // під'єднання/від'єднання пристроїв: якщо найкращий доступний мікрофон
    // змінився — перезапускаємо потік на новому, не гублячи сам факт
    // очікування (квест і так ще не почався).
    final deviceChangeSub = AudioDeviceService.onDevicesChanged.listen((
      _,
    ) async {
      if (completer.isCompleted) return;
      final newDevice = await _resolveInputDevice();
      // Поки гарнітура на місці, лишаємось на ній: підняття голосового
      // каналу перебудовує список входів, і без цієї умови автопідбір
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
      // Новий пристрій — знову спершу пробуємо власний канал.
      pluginScoFallback = false;
      await restartStream();
    });

    final stopTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (isStopRequested()) finish(false);
    });

    try {
      final result = await completer.future;
      return result;
    } finally {
      stopTimer.cancel();
      levelTimer.cancel();
      await deviceChangeSub.cancel();
      await sub?.cancel();
      try {
        await _recorder.stop();
      } catch (_) {}
      if (scoOwned) {
        // Знімаємо завжди: квест підніме канал сам (CommunicationRouter
        // один на застосунок), а очікуванню він більше не потрібен.
        scoOwned = false;
        await _deviceService.stopSco();
      }
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

  /// Чи схоже почуте на справжнє мовлення, а не на випадковий вигук чи шум:
  /// Vosk у тиші раз у раз «чує» одне коротке слово («а», «і», «та») — на
  /// таке зазивайло озиватись не має. Два слова й хоча б шість літер —
  /// уже хтось говорить.
  static bool _soundsLikeSpeech(String text) {
    final tokens = text
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.length < 2) return false;
    return tokens.fold<int>(0, (sum, t) => sum + t.length) >= 6;
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

/// Рівень сигналу мікрофона (PCM16 моно) за проміжок: пік і середнє (RMS)
/// у дБ відносно повної шкали. Дешево: один прохід по семплах шматка.
class _LevelMeter {
  int _peak = 0;
  double _sumSquares = 0;
  int _samples = 0;

  void add(Uint8List chunk) {
    final data = ByteData.sublistView(chunk);
    final n = data.lengthInBytes ~/ 2;
    for (var i = 0; i < n; i++) {
      final s = data.getInt16(i * 2, Endian.little);
      final a = s < 0 ? -s : s;
      if (a > _peak) _peak = a;
      _sumSquares += s * s;
    }
    _samples += n;
  }

  static String _db(double ratio) {
    if (ratio <= 0) return '−∞ дБ';
    return '${(20 * math.log(ratio) / math.ln10).toStringAsFixed(0)} дБ';
  }

  /// Один рядок для журналу; лічильники обнуляються.
  String reportAndReset() {
    if (_samples == 0) {
      return 'жодного шматка звуку — мікрофон не віддає даних';
    }
    final peak = _peak / 32768.0;
    final rms = math.sqrt(_sumSquares / _samples) / 32768.0;
    final buf = StringBuffer('пік ${_db(peak)}, середній ${_db(rms)}');
    if (peak < 0.002) {
      buf.write(' — практично тиша: мікрофон нічого не чує');
    } else if (peak > 0.98) {
      buf.write(' — перевантаження');
    }
    _peak = 0;
    _sumSquares = 0;
    _samples = 0;
    return buf.toString();
  }
}

import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../services/audio_device_service.dart';
import '../services/settings_store.dart';
import 'native_pcm_player.dart';

/// Мікрофон і відтворення голосу персонажа — навмисно ДВІ РІЗНІ реалізації:
/// `record` для захоплення мікрофону, власний нативний AudioTrack-плеєр
/// (NativePcmPlayer / PcmAudioPlayer.kt) для відтворення. Раніше обидва
/// напрямки йшли через flutter_sound, чий плеєр спричинив ТРИ підтверджені
/// нативні SIGSEGV на реальному пристрої (AudioTrack.write() ->
/// AudioTrack::releaseBuffer(), null pointer dereference) — навіть після
/// того, як мікрофон перестав працювати одночасно з відтворенням. Причина
/// була в самому плеєрі flutter_sound, тож його прибрано повністю.
///
/// Половинний дуплекс: поки персонаж говорить, мікрофон апаратно вимкнено
/// (не просто ігнорується на Dart-рівні) — так само, як
/// web/static/quest-gemini.js::markSpeaking() робить це в браузері (мутимо,
/// поки не «дограє» черга відтворення).
class AudioPipeline {
  final AudioRecorder _recorder = AudioRecorder();
  final NativePcmPlayer _player = NativePcmPlayer();
  final AudioDeviceService _deviceService = AudioDeviceService();
  final SettingsStore _settings = SettingsStore();

  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<void>? _deviceChangeSub;
  bool _opened = false;
  bool _muted = false;
  bool _recorderRunning = false;
  double _queuedUntil = 0; // монотонний час (секунди) спорожнення черги
  Timer? _unmuteTimer;
  final _stopwatch = Stopwatch();
  Future<void> _micOpChain = Future<void>.value();

  int? _inputSampleRate;
  void Function(Uint8List pcm16)? _onMic;
  AudioDevice? _resolvedInputDevice;
  AudioDevice? _resolvedOutputDevice;
  bool _voicePlayback = false;
  int? _outputSampleRate;

  /// Прив'язати вихід до обраного пристрою.
  ///
  /// Коли грає канал розмови (SCO), пристрій НЕ називаємо: та сама
  /// гарнітура присутня у списку виходів і як A2DP, а A2DP на час SCO
  /// призупинено — прив'язка до нього дала б тишу. Маршрутизацію в цьому
  /// режимі система робить сама, за активним пристроєм розмови.
  Future<void> _applyOutputRouting() async {
    if (_voicePlayback) {
      await _deviceService.setOutputDevice(null);
      return;
    }
    if (_resolvedOutputDevice != null) {
      await _deviceService.setOutputDevice(_resolvedOutputDevice!.id);
    }
  }

  // Плеєр стартує асинхронно (нативний виклик), а перший шматок голосу
  // персонажа може прийти від транспорту раніше, ніж він встигне
  // ініціалізуватися. Тож до готовності буферизуємо шматки й віддаємо їх
  // по черзі (нативний бік і сам безпечно ігнорує write() до готовності,
  // це — додатковий захист про всяк випадок).
  bool _playerReady = false;
  final List<(Uint8List, int)> _pendingChunks = [];

  // Чи прийшов хоч один шматок голосу персонажа за поточний квест —
  // запобіжник від _muted=true "назавжди", якщо хід раптом завершився
  // взагалі без аудіо (напр. збій транспорту).
  bool _everFed = false;

  final _diagCtrl = StreamController<String>.broadcast();

  /// Людяні діагностичні повідомлення про вибір аудіо-пристрою: який
  /// вхід/вихід обрано (і чому), коли мікрофон реально стартує з ним.
  /// Показується в транскрипті квесту — інакше "не чує зовнішній мікрофон"
  /// неможливо відрізнити від "автопідбір обрав не той пристрій" наосліп.
  Stream<String> get diagnostics => _diagCtrl.stream;

  bool get isMuted => _muted;

  Future<void> open() async {
    if (_opened) return;
    _stopwatch.start();
    _opened = true;
  }

  double get _now => _stopwatch.elapsedMicroseconds / 1e6;

  /// Виконати наступну операцію з мікрофоном лише після завершення
  /// попередньої — інакше start()/stop() можуть накластися один на одного.
  Future<void> _queueMicOp(Future<void> Function() op) {
    final next = _micOpChain.then((_) => op()).catchError((_) {});
    _micOpChain = next;
    return next;
  }

  Future<void> _startRecorderStream() async {
    if (_recorderRunning || _inputSampleRate == null) return;
    _recorderRunning = true;
    final device = _resolvedInputDevice;
    _diagCtrl.add(
      device == null
          ? 'Мікрофон: стартую на пристрої за замовчуванням (автопідбір '
                'недоступний або нічого не знайдено).'
          : 'Мікрофон: стартую на «${device.label}» (${_bucketLabel(device.bucket)}).',
    );
    final micStream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _inputSampleRate!,
        numChannels: 1,
        // ‼️ Для Bluetooth пристрій навмисно НЕ називаємо — те саме, що й у
        // WakeGateService: плагін `record` вимикає (і навіть рве) власне
        // керування SCO, якщо переданий пристрій має тип, відмінний від
        // TYPE_BLUETOOTH_SCO, а гарнітура присутня у списку і як BLE/A2DP.
        // З null він піднімає канал сам і чекає на з'єднання перед записом.
        device: (device == null || device.bucket == 'bluetooth')
            ? null
            : InputDevice(id: device.id, label: device.label),
        androidConfig: const AndroidRecordConfig(manageBluetooth: true),
      ),
    );
    _micSub = micStream.listen((data) => _onMic?.call(data));
  }

  String _bucketLabel(String bucket) {
    switch (bucket) {
      case 'wired':
        return 'провідний';
      case 'bluetooth':
        return 'bluetooth';
      case 'builtin':
        return 'вбудований';
      default:
        return bucket;
    }
  }

  /// Перечитати список входу/виходу й обрати найкращий: власний вибір
  /// користувача (якщо досі доступний), інакше автоматично за пріоритетом
  /// (провідний → bluetooth → вбудований).
  Future<void> _resolveAudioDevices() async {
    try {
      final inputs = await _deviceService.listInputDevices();
      final outputs = await _deviceService.listOutputDevices();
      final preferredIn = await _settings.getPreferredInputDeviceId();
      final preferredOut = await _settings.getPreferredOutputDeviceId();

      // Якщо доступний лише ОДИН пристрій (типовий випадок — жодного
      // зовнішнього не під'єднано) і користувач нічого явно не обрав у
      // налаштуваннях — не чіпаємо маршрутизацію взагалі й лишаємо
      // Android-у самому нею керувати, як і до цієї фічі. Явний виклик
      // setPreferredDevice()/RecordConfig.device в цьому тривіальному
      // випадку (нема з чого обирати) призводив до повної тиші — регресія,
      // підтверджена на реальному пристрої без жодного зовнішнього гаджета.
      _resolvedInputDevice = (inputs.length > 1 || preferredIn != null)
          ? AudioDeviceService.resolve(inputs, preferredIn)
          : null;
      _resolvedOutputDevice = (outputs.length > 1 || preferredOut != null)
          ? AudioDeviceService.resolve(outputs, preferredOut)
          : null;

      _diagCtrl.add(
        'Знайдено пристроїв: вхід ${inputs.length}, вихід ${outputs.length}. '
        'Обрано: вхід «${_resolvedInputDevice?.label ?? "за замовчуванням"}», '
        'вихід «${_resolvedOutputDevice?.label ?? "за замовчуванням"}».',
      );
    } catch (e) {
      // Автопідбір недоступний (старий Android / помилка) — лишаємось на
      // пристрої за замовчуванням, як і раніше.
      _diagCtrl.add('Автопідбір аудіо-пристрою недоступний: $e');
    }
  }

  // Рахунок кожного виклику _onDevicesChanged(), що чекає на "усідання"
  // щойно з'явленого Bluetooth-виходу — щоб застаріле очікування (пристрій
  // від'єднався чи змінився ще раз, поки ми чекали) не застосувало вже
  // неактуальний вибір.
  int _outputSettleToken = 0;

  /// Реакція на під'єднання/від'єднання аудіо-пристрою: переобрати
  /// найкращий доступний БЕЗ переривання сесії. Вихід перемикається на
  /// льоту (AudioTrack.setPreferredDevice не потребує зупинки), вхід
  /// перезапускається лише якщо він зараз активний і справді змінився.
  Future<void> _onDevicesChanged() async {
    if (!_opened) return;
    final prevInputId = _resolvedInputDevice?.id;
    final prevOutputId = _resolvedOutputDevice?.id;
    await _resolveAudioDevices();

    if (_resolvedOutputDevice?.id != prevOutputId) {
      final token = ++_outputSettleToken;
      // Щойно з'явлений Bluetooth-вихід (колонка, автомобільна магнітола)
      // система показує в списку пристроїв ще ДО того, як фактично
      // завершилось узгодження аудіо-профілю — прив'язка AudioTrack до
      // нього в цю мить веде в тишу без жодної помилки. Провідні пристрої
      // й гарнітури, що вже стабільно під'єднані, такої затримки не мають,
      // тож чекаємо лише для bluetooth.
      var superseded = false;
      if (_resolvedOutputDevice != null &&
          _resolvedOutputDevice!.bucket == 'bluetooth') {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        // Поки чекали, прилетіла новіша зміна — маршрут виходу застосує
        // саме вона. Але з ФУНКЦІЇ виходити не можна: нижче ще перемикання
        // режиму відтворення й перезапуск мікрофона. Раніше тут стояв
        // return, і при під'єднанні/від'єднанні гарнітури (а Android сипле
        // такими подіями пачками) режим відтворення лишався старим —
        // медіа при піднятому SCO або навпаки. Саме через це голос
        // персонажа пропадав після кожного перемикання пристрою.
        superseded = token != _outputSettleToken || !_opened;
        if (!superseded) await _resolveAudioDevices();
      }
      if (!superseded) await _applyOutputRouting();
    }
    // Гарнітуру під'єднали (чи від'єднали) посеред квесту — режим
    // відтворення треба переузгодити: канал розмови для гарнітури, медіа
    // для всього іншого.
    final wantVoice = _resolvedInputDevice?.bucket == 'bluetooth';
    if (wantVoice != _voicePlayback) {
      await _restartPlayer(wantVoice);
    }
    if (_resolvedInputDevice?.id != prevInputId) {
      if (_recorderRunning) {
        await _queueMicOp(_stopRecorderStream);
        await _queueMicOp(_startRecorderStream);
      }
    }
  }

  /// Перестворити плеєр у потрібному режимі (канал розмови ↔ медіа).
  ///
  /// Поки він перестворюється, шматки голосу НЕ викидаємо, а складаємо в
  /// чергу й дограємо після — інакше репліка, що саме звучала в мить
  /// перемикання пристрою, зникала б безслідно.
  Future<void> _restartPlayer(bool voice) async {
    _voicePlayback = voice;
    final rate = _outputSampleRate;
    if (rate == null) return; // плеєр ще жодного разу не стартував
    _playerReady = false;
    await _player.stop();
    await _player.start(rate, voiceCommunication: voice);
    await _applyOutputRouting();
    _playerReady = true;
    final pending = List<(Uint8List, int)>.from(_pendingChunks);
    _pendingChunks.clear();
    for (final (chunk, chunkRate) in pending) {
      await _feedNow(chunk, chunkRate);
    }
    _diagCtrl.add(
      voice
          ? 'Голос персонажа: канал розмови (Bluetooth-гарнітура).'
          : 'Голос персонажа: звичайне медіа-відтворення.',
    );
  }

  Future<void> _stopRecorderStream() async {
    if (!_recorderRunning) return;
    _recorderRunning = false;
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
  }

  /// Почати захоплення мікрофону й потоковий програвач голосу персонажа.
  /// [onMic] отримує сирі PCM16-шматки — лише поки персонаж мовчить,
  /// оскільки мікрофон апаратно вимкнено на час його репліки.
  Future<void> start({
    required int inputSampleRate,
    required int outputSampleRate,
    required void Function(Uint8List pcm16) onMic,
  }) async {
    await open();
    // Мікрофон СТАРТУЄ заглушеним і апаратно вимкненим: персонаж повинен
    // договорити своє привітання (перший хід), перш ніж почує дітей.
    // Раніше мікрофон вмикався одразу, тож живий шум летів у Gemini
    // одночасно з генерацією привітання й міг спричинити самоперебивання
    // ще до того, як перший шматок голосу персонажа встигав заглушити
    // мікрофон через _muteFor() — звідси озвучка була відсутня для самого
    // першого повідомлення. Мікрофон вмикається природно через
    // unmute-таймер у _muteFor(), коли черга відтворення дограє.
    _muted = true;
    _everFed = false;
    _queuedUntil = 0;
    _playerReady = false;
    _pendingChunks.clear();
    _inputSampleRate = inputSampleRate;
    _onMic = onMic;

    await _resolveAudioDevices();
    await _deviceChangeSub?.cancel();
    _deviceChangeSub = AudioDeviceService.onDevicesChanged.listen((_) {
      unawaited(_onDevicesChanged());
    });

    // Гарнітура (мікрофон по bluetooth) означає, що зараз піднято SCO — і
    // голос персонажа має йти тим самим каналом розмови, інакше в гарнітуру
    // не потрапить нічого. Для колонки без мікрофона лишається звичайне
    // медіа-відтворення з повною якістю.
    _outputSampleRate = outputSampleRate;
    _voicePlayback = _resolvedInputDevice?.bucket == 'bluetooth';
    await _player.start(outputSampleRate, voiceCommunication: _voicePlayback);
    if (_voicePlayback) {
      _diagCtrl.add(
        'Голос персонажа: канал розмови (через Bluetooth-гарнітуру).',
      );
    }
    await _applyOutputRouting();

    _playerReady = true;
    final pending = List<(Uint8List, int)>.from(_pendingChunks);
    _pendingChunks.clear();
    for (final (chunk, rate) in pending) {
      await _feedNow(chunk, rate);
    }
  }

  /// Додати шматок голосу персонажа в чергу відтворення й продовжити
  /// «заглушення» мікрофону, поки черга не спорожніє. Якщо плеєр ще не
  /// стартував (гонитва з першим шматком від транспорту) — буферизуємо.
  Future<void> playAgentChunk(Uint8List pcm16, int sampleRate) async {
    if (!_opened) return;
    if (!_playerReady) {
      _pendingChunks.add((pcm16, sampleRate));
      return;
    }
    await _feedNow(pcm16, sampleRate);
  }

  Future<void> _feedNow(Uint8List pcm16, int sampleRate) async {
    _everFed = true;
    _muteFor(pcm16.length, sampleRate);
    await _player.write(pcm16);
  }

  void _muteFor(int byteLength, int sampleRate) {
    final wasMuted = _muted;
    final samples = byteLength / 2; // PCM16 = 2 байти на семпл
    final duration = samples / sampleRate;
    final now = _now;
    _queuedUntil = (_queuedUntil < now ? now : _queuedUntil) + duration;
    _muted = true;

    if (!wasMuted) {
      // Персонаж щойно почав говорити — вимикаємо мікрофон апаратно, щоб
      // AudioRecord і AudioTrack не працювали одночасно.
      unawaited(_queueMicOp(_stopRecorderStream));
    }

    _unmuteTimer?.cancel();
    final ms = (((_queuedUntil - now) * 1000).round() + 500)
        .clamp(0, 60000)
        .toInt();
    final delay = Duration(milliseconds: ms);
    _unmuteTimer = Timer(delay, () {
      _muted = false;
      unawaited(_queueMicOp(_startRecorderStream));
    });
  }

  /// Викликати після завершення ходу персонажа (turnComplete): якщо за
  /// весь хід не прийшло жодного шматка аудіо (мікрофон і досі заглушений
  /// самим стартовим станом), примусово розблокувати — інакше розмова
  /// застрягне в тиші назавжди.
  void unmuteIfNoAudioYet() {
    if (!_everFed && _muted) {
      unmuteNow();
    }
  }

  /// Зачекати, поки черга відтворення голосу персонажа спорожніє (щоб не
  /// перервати останню репліку, коли перемога вже зафіксована).
  Future<void> waitDrained({
    Duration maxWait = const Duration(seconds: 15),
  }) async {
    final deadline = _now + maxWait.inMilliseconds / 1000;
    while (_queuedUntil > _now && _now < deadline) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Негайно зняти заглушення (напр. після ручної зупинки відтворення).
  void unmuteNow() {
    _unmuteTimer?.cancel();
    _muted = false;
    _queuedUntil = 0;
    unawaited(_queueMicOp(_startRecorderStream));
  }

  Future<void> stop() async {
    _unmuteTimer?.cancel();
    _unmuteTimer = null;
    _playerReady = false;
    _pendingChunks.clear();
    _onMic = null;
    await _deviceChangeSub?.cancel();
    _deviceChangeSub = null;
    await _queueMicOp(_stopRecorderStream);
    await _player.stop();
    _muted = false;
  }

  Future<void> dispose() async {
    await stop();
    _opened = false;
    try {
      await _recorder.dispose();
    } catch (_) {}
    _stopwatch.stop();
    await _diagCtrl.close();
  }
}

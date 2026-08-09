import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

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

  StreamSubscription<Uint8List>? _micSub;
  bool _opened = false;
  bool _muted = false;
  bool _recorderRunning = false;
  double _queuedUntil = 0; // монотонний час (секунди) спорожнення черги
  Timer? _unmuteTimer;
  final _stopwatch = Stopwatch();
  Future<void> _micOpChain = Future<void>.value();

  int? _inputSampleRate;
  void Function(Uint8List pcm16)? _onMic;

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
    final micStream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _inputSampleRate!,
        numChannels: 1,
      ),
    );
    _micSub = micStream.listen((data) => _onMic?.call(data));
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

    await _player.start(outputSampleRate);

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
  }
}

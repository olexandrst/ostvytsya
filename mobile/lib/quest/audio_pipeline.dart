import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart'
    show Codec, FlutterSoundPlayer;
import 'package:record/record.dart';

/// Мікрофон і відтворення голосу персонажа — навмисно ДВІ РІЗНІ бібліотеки:
/// `record` для захоплення, `flutter_sound` лише для відтворення. Раніше
/// обидва напрямки йшли через flutter_sound — окреме розділення пакетів
/// саме по собі не прибрало нативний SIGSEGV у AudioTrack (підтверджено
/// повторним крахом із тим самим сигнатуром навіть після розділення), тож
/// причина глибша за flutter_sound: цей конкретний пристрій (Samsung
/// Galaxy A35, Android 16) не витримує, коли AudioRecord (мікрофон) і
/// AudioTrack (колонка) апаратно активні ОДНОЧАСНО, незалежно від того,
/// який плагін ними керує.
///
/// Тому мікрофон тепер апаратно ЗУПИНЯЄТЬСЯ на час, поки персонаж говорить
/// (а не просто ігнорується на Dart-рівні, як було раніше), і стартує знову
/// щойно черга відтворення спорожніє — AudioRecord і AudioTrack ніколи не
/// працюють одночасно. Старт/стоп мікрофона серіалізовано через _micOpChain,
/// щоб не накладати виклики один на одного.
class AudioPipeline {
  final AudioRecorder _recorder = AudioRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

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
  // персонажа може прийти від транспорту раніше, ніж startPlayerFromStream
  // встигне завершитися — годування ще не готового плеєра валило нативний
  // код. Тож до готовності буферизуємо шматки й віддаємо їх по черзі.
  bool _playerReady = false;
  final List<(Uint8List, int)> _pendingChunks = [];

  bool get isMuted => _muted;

  Future<void> open() async {
    if (_opened) return;
    await _player.openPlayer();
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
    _muted = false;
    _queuedUntil = 0;
    _playerReady = false;
    _pendingChunks.clear();
    _inputSampleRate = inputSampleRate;
    _onMic = onMic;

    await _queueMicOp(_startRecorderStream);

    await _player.startPlayerFromStream(
      codec: Codec.pcm16,
      interleaved: true,
      numChannels: 1,
      sampleRate: outputSampleRate,
      bufferSize: 4096,
    );

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
    _muteFor(pcm16.length, sampleRate);
    try {
      await _player.feedUint8FromStream(pcm16);
    } catch (_) {
      // Плеєр міг уже зупинитися (квест завершується) — це не помилка.
    }
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
    try {
      await _player.stopPlayer();
    } catch (_) {}
    _muted = false;
  }

  Future<void> dispose() async {
    await stop();
    if (_opened) {
      await _player.closePlayer();
      _opened = false;
    }
    try {
      await _recorder.dispose();
    } catch (_) {}
    _stopwatch.stop();
  }
}

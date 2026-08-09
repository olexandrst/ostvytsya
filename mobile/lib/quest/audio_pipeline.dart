import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart'
    show Codec, FlutterSoundPlayer;
import 'package:record/record.dart';

/// Мікрофон і відтворення голосу персонажа — навмисно ДВІ РІЗНІ бібліотеки:
/// `record` для захоплення, `flutter_sound` лише для відтворення. Раніше
/// обидва напрямки йшли через flutter_sound, і це спричиняло справжній
/// нативний SIGSEGV у AudioTrack (підтверджено crash-трасуванням з
/// пристрою) — одночасне використання recorder+player в flutter_sound є
/// відомою невирішеною проблемою пакета (github.com/Canardoux/flutter_sound
/// issue #1091). Розділення на дві незалежні нативні реалізації прибирає
/// спільний внутрішній стан, який і падав.
///
/// Половинний дуплекс: поки персонаж говорить, мікрофон вимкнено — так
/// само, як web/static/quest-gemini.js::markSpeaking() робить це в
/// браузері (мутимо, поки не «дограє» черга відтворення).
class AudioPipeline {
  final AudioRecorder _recorder = AudioRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  StreamSubscription<Uint8List>? _micSub;
  bool _opened = false;
  bool _muted = false;
  double _queuedUntil = 0; // монотонний час (секунди) спорожнення черги
  Timer? _unmuteTimer;
  final _stopwatch = Stopwatch();

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

  /// Почати захоплення мікрофону й потоковий програвач голосу персонажа.
  /// [onMic] отримує сирі PCM16-шматки, лише коли мікрофон не заглушено.
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

    final micStream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: inputSampleRate,
        numChannels: 1,
      ),
    );
    _micSub = micStream.listen((data) {
      if (!_muted) onMic(data);
    });

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
    final samples = byteLength / 2; // PCM16 = 2 байти на семпл
    final duration = samples / sampleRate;
    final now = _now;
    _queuedUntil = (_queuedUntil < now ? now : _queuedUntil) + duration;
    _muted = true;

    _unmuteTimer?.cancel();
    final ms = (((_queuedUntil - now) * 1000).round() + 500)
        .clamp(0, 60000)
        .toInt();
    final delay = Duration(milliseconds: ms);
    _unmuteTimer = Timer(delay, () {
      _muted = false;
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
  }

  Future<void> stop() async {
    _unmuteTimer?.cancel();
    _unmuteTimer = null;
    _playerReady = false;
    _pendingChunks.clear();
    try {
      await _recorder.stop();
    } catch (_) {}
    try {
      await _player.stopPlayer();
    } catch (_) {}
    await _micSub?.cancel();
    _micSub = null;
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

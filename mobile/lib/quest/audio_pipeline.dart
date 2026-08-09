import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_sound/flutter_sound.dart';

/// Мікрофон і відтворення голосу персонажа через flutter_sound (одна
/// бібліотека для обох напрямків — менше ризику конфлікту аудіосесії на
/// Android). Половинний дуплекс: поки персонаж говорить, мікрофон
/// вимкнено — так само, як web/static/quest-gemini.js::markSpeaking()
/// робить це в браузері (мутимо, поки не «дограє» черга відтворення).
class AudioPipeline {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  StreamController<Uint8List>? _micRaw;
  StreamSubscription<Uint8List>? _micSub;
  bool _opened = false;
  bool _muted = false;
  double _queuedUntil = 0; // монотонний час (секунди) спорожнення черги
  Timer? _unmuteTimer;
  final _stopwatch = Stopwatch();

  bool get isMuted => _muted;

  Future<void> open() async {
    if (_opened) return;
    await _recorder.openRecorder();
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

    _micRaw = StreamController<Uint8List>();
    _micSub = _micRaw!.stream.listen((data) {
      if (!_muted) onMic(data);
    });

    await _recorder.startRecorder(
      codec: Codec.pcm16,
      toStream: _micRaw!.sink,
      sampleRate: inputSampleRate,
      numChannels: 1,
      audioSource: AudioSource.microphone,
      enableEchoCancellation: true,
    );

    await _player.startPlayerFromStream(
      codec: Codec.pcm16,
      interleaved: true,
      numChannels: 1,
      sampleRate: outputSampleRate,
      bufferSize: 4096,
    );
  }

  /// Додати шматок голосу персонажа в чергу відтворення й продовжити
  /// «заглушення» мікрофону, поки черга не спорожніє.
  Future<void> playAgentChunk(Uint8List pcm16, int sampleRate) async {
    if (!_opened) return;
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
    try {
      await _recorder.stopRecorder();
    } catch (_) {}
    try {
      await _player.stopPlayer();
    } catch (_) {}
    await _micSub?.cancel();
    await _micRaw?.close();
    _micSub = null;
    _micRaw = null;
    _muted = false;
  }

  Future<void> dispose() async {
    await stop();
    if (_opened) {
      await _recorder.closeRecorder();
      await _player.closePlayer();
      _opened = false;
    }
    _stopwatch.stop();
  }
}

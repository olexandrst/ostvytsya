import 'package:flutter/services.dart';

/// Dart-місток до самописного нативного PCM16-плеєра (PcmAudioPlayer.kt).
///
/// Заміна плеєра flutter_sound, який спричинив три підтверджені нативні
/// SIGSEGV на реальному пристрої (AudioTrack.write() ->
/// AudioTrack::releaseBuffer(), null pointer dereference) — навіть після
/// того, як мікрофон перестав працювати одночасно з відтворенням. Проблема
/// була в самому плеєрі, тож замість нього — власний мінімальний
/// AudioTrack-плеєр з чіткою серіалізацією write/stop на нативному боці.
class NativePcmPlayer {
  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );

  Future<void> start(int sampleRate) async {
    try {
      await _channel.invokeMethod('pcmPlayerStart', {'sampleRate': sampleRate});
    } on PlatformException {
      // Плеєр міг не піднятися — шматки просто нікуди не підуть, без краху.
    }
  }

  Future<void> write(Uint8List pcm16) async {
    try {
      await _channel.invokeMethod('pcmPlayerWrite', {'bytes': pcm16});
    } on PlatformException {
      // Один пропущений шматок — не критично для квесту.
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('pcmPlayerStop');
    } on PlatformException {
      // Плеєр міг і не стартувати — нема що зупиняти.
    }
  }
}

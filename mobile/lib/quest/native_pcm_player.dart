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

  /// [voiceCommunication] — відтворювати як голос розмови (канал SCO), а не
  /// як медіа. Потрібно для Bluetooth-гарнітури: поки піднято SCO заради її
  /// мікрофона, профіль A2DP призупинено, і медіа-потік у гарнітуру не
  /// потрапляє взагалі.
  Future<void> start(int sampleRate, {bool voiceCommunication = false}) async {
    try {
      await _channel.invokeMethod('pcmPlayerStart', {
        'sampleRate': sampleRate,
        'voiceCommunication': voiceCommunication,
      });
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

  /// [drain] = true — дати нативному плеєру ДОГРАТИ все передане (кінець
  /// квесту: фінальна репліка не має обриватись); false — зупинити негайно
  /// (кнопка «Зупинити», аварія).
  Future<void> stop({bool drain = false}) async {
    try {
      await _channel.invokeMethod('pcmPlayerStop', {'drain': drain});
    } on PlatformException {
      // Плеєр міг і не стартувати — нема що зупиняти.
    }
  }
}

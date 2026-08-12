import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Dart-місток до нативного AAC/.m4a кодера сесії (SessionAacEncoder.kt).
///
/// Стиснення відбувається на нативному боці (MediaCodec + MediaMuxer) —
/// той самий підхід, що й у NativePcmPlayer/PcmAudioPlayer.kt: власний
/// мінімальний нативний код замість стороннього Flutter-плагіна для
/// аудіо, з якими вже був негативний досвід (flutter_sound спричиняв
/// нативні SIGSEGV на реальному пристрої).
class NativeSessionEncoder {
  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );

  Future<void> start(String path, int sampleRate) async {
    try {
      await _channel.invokeMethod('sessionEncoderStart', {
        'path': path,
        'sampleRate': sampleRate,
      });
    } on PlatformException {
      // Кодер міг не піднятися — шматки просто нікуди не підуть, без краху.
    }
  }

  Future<void> write(Uint8List pcm16) async {
    try {
      await _channel.invokeMethod('sessionEncoderWrite', {'bytes': pcm16});
    } on PlatformException {
      // Один пропущений шматок — не критично для запису.
    }
  }

  /// Повертається лише коли .m4a-файл повністю дописано й закрито.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod('sessionEncoderStop');
    } on PlatformException {
      // Кодер міг і не стартувати — нема що зупиняти.
    }
  }
}

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

  /// Почати запис. [name] — ім'я файлу у спільній медіатеці
  /// (`Music/Оствиця`), [fallbackPath] — куди писати, якщо медіатека
  /// недоступна (Android 9 і старіші).
  ///
  /// Повертає `content://`-URI створеного запису в медіатеці, або null, якщо
  /// довелось відкотитись на файл за [fallbackPath].
  Future<String?> start(
    String name,
    String fallbackPath,
    int sampleRate,
  ) async {
    try {
      return await _channel.invokeMethod<String>('sessionEncoderStart', {
        'name': name,
        'fallbackPath': fallbackPath,
        'sampleRate': sampleRate,
      });
    } on PlatformException {
      // Кодер міг не піднятися — шматки просто нікуди не підуть, без краху.
      return null;
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

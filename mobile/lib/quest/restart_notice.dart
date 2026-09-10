import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// Голосове оголошення після перезапуску квесту з панелі:
/// «УВАГА! Інтерактивного персонажа перезапущено. Щоб розпочати новий
/// квест — промовте кодове слово».
///
/// Джерело звуку — навмисно НЕ Gemini (жодних токенів): спершу локальний
/// запис `assets/audio/restart_notice.mp3` (див. scripts/make_restart_notice.py
/// і assets/audio/README.md), а якщо файла в збірці немає — системний
/// синтезатор Android з українським голосом. Повертає, чим саме озвучено
/// (для журналу сесії).
class RestartNotice {
  static const text =
      'УВАГА! Інтерактивного персонажа перезапущено. '
      'Щоб розпочати новий квест — промовте кодове слово.';

  /// Шлях відносно теки assets/ (так його очікує audioplayers).
  static const asset = 'audio/restart_notice.mp3';

  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );

  static Future<String> play() async {
    if (await _playAsset()) return 'локальний запис';
    if (await _speakWithDeviceTts()) return 'синтезатор Android';
    return 'не вдалося: немає ні запису в assets, ні українського голосу '
        'Android';
  }

  static Future<bool> _playAsset() async {
    try {
      // Кидає, якщо файла в збірці немає — тоді резервний варіант нижче.
      final data = await rootBundle.load('assets/$asset');
      if (data.lengthInBytes == 0) return false;
    } catch (_) {
      return false;
    }
    final player = AudioPlayer();
    try {
      final done = player.onPlayerComplete.first;
      await player.play(AssetSource(asset));
      await done.timeout(const Duration(seconds: 20));
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await player.dispose();
      } catch (_) {}
    }
  }

  static Future<bool> _speakWithDeviceTts() async {
    try {
      final ok = await _channel
          .invokeMethod<bool>('ttsSpeak', {'text': text, 'language': 'uk-UA'})
          .timeout(const Duration(seconds: 25));
      return ok == true;
    } catch (_) {
      return false;
    }
  }
}

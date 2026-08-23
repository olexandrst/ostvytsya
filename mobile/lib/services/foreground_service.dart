import 'package:flutter/services.dart';

/// Dart-місток до нативного QuestForegroundService (Kotlin): тримає процес
/// живим і активним, поки квест триває — навіть з вимкненим екраном.
class ForegroundServiceControl {
  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );

  Future<void> start() async {
    try {
      await _channel.invokeMethod('startService');
    } on PlatformException {
      // Немає сенсу валити квест лише через те, що сповіщення не піднялося.
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod('stopService');
    } on PlatformException {
      // Сервіс міг і не стартувати — нема що зупиняти.
    }
  }

  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } on PlatformException {
      // Діалог системи міг не відкритися — не критично для квесту.
    }
  }
}

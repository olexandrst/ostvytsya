import 'package:flutter/services.dart';

/// Читає журнал останнього нативного краху (записаного
/// OstvytsyaApplication.kt перед тим, як процес завершився) — щоб
/// показати текст просто в застосунку. Потрібно на реальних пристроях
/// без adb: інакше після краху не лишається жодного видимого сліду.
class CrashLogService {
  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );

  Future<String?> readLastCrash() async {
    try {
      return await _channel.invokeMethod<String>('getLastCrashLog');
    } on PlatformException {
      return null;
    }
  }

  Future<void> clearLastCrash() async {
    try {
      await _channel.invokeMethod('clearLastCrashLog');
    } on PlatformException {
      // Нема журналу — нема що чистити.
    }
  }
}

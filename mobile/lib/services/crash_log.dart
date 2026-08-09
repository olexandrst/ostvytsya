import 'package:flutter/services.dart';

/// Читає журнал останнього краху застосунку — з двох джерел:
///   * файл, який пише OstvytsyaApplication.kt через
///     Thread.setDefaultUncaughtExceptionHandler (бачить лише Java/Kotlin
///     винятки);
///   * ActivityManager.getHistoricalProcessExitReasons (Android 11+) —
///     причина останнього завершення процесу від самої системи, включно зі
///     СПРАВЖНІМИ нативними падіннями (SIGSEGV у бібліотеці), які перший
///     спосіб не бачить узагалі, бо це не Java-виняток.
/// Обидва потрібні на реальних пристроях без adb: інакше після краху не
/// лишається жодного видимого сліду.
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

  Future<String?> readLastExitReason() async {
    try {
      return await _channel.invokeMethod<String>('getLastExitReason');
    } on PlatformException {
      return null;
    }
  }

  Future<void> acknowledgeExitReason() async {
    try {
      await _channel.invokeMethod('acknowledgeExitReason');
    } on PlatformException {
      // Немає причини для підтвердження — не критично.
    }
  }
}

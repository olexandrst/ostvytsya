import 'package:flutter/services.dart';

import '../constants.dart';

/// Версія встановленого APK: `versionName` і `versionCode` читаються нативно
/// з пакета (див. MainActivity, метод `appVersion`), тож показують саме ту
/// збірку, що стоїть на телефоні.
///
/// Номер версії кожної збірки задає CI (`--build-name` / `--build-number` у
/// .github/workflows/mobile-build.yml, номер запуску збірки), тому дві різні
/// збірки ніколи не виглядають однаково, а `versionCode` лише зростає — без
/// цього Android не дав би поставити нову версію поверх старої.
///
/// Значення читається один раз на старті застосунку ([load]) і далі доступне
/// синхронно — його беруть і екран налаштувань, і шапка журналу сесії.
class AppVersion {
  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );

  /// Напр. «1.1.87». Порожньо, поки [load] не виконалась (або на не-Android).
  static String name = '';

  /// Наскрізний номер збірки (versionCode); 0 — невідомо.
  static int code = 0;

  static Future<void> load() async {
    try {
      final info = await _channel.invokeMapMethod<String, Object?>('appVersion');
      if (info == null) return;
      name = (info['name'] as String?)?.trim() ?? '';
      code = (info['code'] as num?)?.toInt() ?? 0;
    } catch (_) {
      // Версія — суто довідкова: не змогли прочитати, покажемо коміт.
    }
  }

  /// Рядок для людини: «1.1.87 (збірка 87) · 56f20ef». Коміт (kAppVersion)
  /// додається, коли APK зібрано в CI, — за ним знаходять точний код збірки.
  static String get label {
    final parts = <String>[];
    if (name.isNotEmpty) {
      parts.add(code > 0 ? '$name (збірка $code)' : name);
    }
    if (kAppVersion.isNotEmpty) parts.add(kAppVersion);
    if (parts.isEmpty) return 'локальна збірка';
    return parts.join(' · ');
  }
}

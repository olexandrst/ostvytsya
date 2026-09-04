import 'package:flutter/services.dart';

/// Знімок пам'яті процесу й пристрою — для журналу сесії. Коли система
/// вбиває застосунок через LOW_MEMORY, саме ці цифри на початку й наприкінці
/// попередніх сесій показують, ХТО з'їв пам'ять: наш процес (росте від сесії
/// до сесії — витік) чи пристрій загалом (мало вільної ще до старту).
class DeviceMemory {
  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );

  /// Людяний рядок або null, якщо нативний бік не відповів.
  static Future<String?> describe() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'memoryInfo',
      );
      if (raw == null || raw.isEmpty) return null;
      int? mb(String key) => (raw[key] as num?)?.toInt();
      final low = raw['device_low_memory'] == true;
      return 'процес ${mb('process_pss_mb')} МБ '
          '(нативна ${mb('native_heap_mb')}, Java ${mb('java_heap_mb')}); '
          'на пристрої вільно ${mb('device_avail_mb')} '
          'із ${mb('device_total_mb')} МБ'
          '${low ? " — СИСТЕМА ВЖЕ В РЕЖИМІ НЕСТАЧІ ПАМ'ЯТІ" : ''}';
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'device_id_service.dart';
import 'persistent_backup.dart';

/// Ключі API (Gemini, OpenAI) і локальні налаштування пристрою (жодного
/// логіна — усе зберігається лише на цьому пристрої).
class SettingsStore {
  static const _geminiKeyName = 'gemini_api_key';
  static const _openaiKeyName = 'openai_api_key';
  static const _instanceIdName = 'app_instance_id';
  static const _inputDeviceIdName = 'preferred_input_device_id';
  static const _outputDeviceIdName = 'preferred_output_device_id';
  static const _sessionRecordingEnabledName = 'session_recording_enabled';
  static const _statusReportingEnabledName = 'status_reporting_enabled';
  static const _statusServerUrlName = 'status_server_url';

  final _storage = const FlutterSecureStorage();
  final _backup = PersistentBackup();

  /// Усі ключі налаштувань — саме вони потрапляють у резервну копію, яка
  /// переживає видалення застосунку.
  static const _backedUpKeys = [
    _geminiKeyName,
    _openaiKeyName,
    _instanceIdName,
    _inputDeviceIdName,
    _outputDeviceIdName,
    _sessionRecordingEnabledName,
    _statusReportingEnabledName,
    _statusServerUrlName,
  ];

  /// Перекласти поточні налаштування у резервну копію. Викликається після
  /// КОЖНОЇ зміни — налаштувань мало й міняються вони рідко, тож дешевше
  /// щоразу перезаписати все, ніж стежити за окремими ключами.
  Future<void> _syncBackup() async {
    final data = <String, String>{};
    for (final key in _backedUpKeys) {
      final value = await _storage.read(key: key);
      if (value != null) data[key] = value;
    }
    await _backup.saveSettings(jsonEncode(data));
  }

  /// Відновити налаштування з резервної копії, якщо на пристрої їх ще
  /// немає (свіже встановлення застосунку). Наявні значення НЕ чіпаємо —
  /// щоб відновлення ніколи не затерло те, що користувач уже ввів.
  ///
  /// Викликається один раз на старті застосунку, до першого читання
  /// налаштувань.
  Future<void> restoreIfEmpty() async {
    try {
      final existing = await _storage.read(key: _geminiKeyName);
      final existingOpenAi = await _storage.read(key: _openaiKeyName);
      if ((existing != null && existing.isNotEmpty) ||
          (existingOpenAi != null && existingOpenAi.isNotEmpty)) {
        return;
      }
      final raw = await _backup.loadSettings();
      if (raw == null || raw.isEmpty) return;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in data.entries) {
        if (!_backedUpKeys.contains(entry.key)) continue;
        final current = await _storage.read(key: entry.key);
        if (current != null && current.isNotEmpty) continue;
        await _storage.write(key: entry.key, value: '${entry.value}');
      }
    } catch (_) {
      // Пошкоджена чи нечитабельна копія не має заважати запуску — просто
      // працюємо з чистими налаштуваннями, як і раніше.
    }
  }

  Future<String?> getGeminiApiKey() => _storage.read(key: _geminiKeyName);
  Future<String?> getOpenAiApiKey() => _storage.read(key: _openaiKeyName);

  Future<void> setGeminiApiKey(String value) async {
    final v = value.trim();
    if (v.isEmpty) {
      await _storage.delete(key: _geminiKeyName);
    } else {
      await _storage.write(key: _geminiKeyName, value: v);
    }
    await _syncBackup();
  }

  Future<void> setOpenAiApiKey(String value) async {
    final v = value.trim();
    if (v.isEmpty) {
      await _storage.delete(key: _openaiKeyName);
    } else {
      await _storage.write(key: _openaiKeyName, value: v);
    }
    await _syncBackup();
  }

  /// Ідентифікатор цього примірника застосунку — за замовчуванням
  /// детермінований з Android ID цього конкретного телефону (стабільний
  /// між перевстановленнями застосунку), але користувач може замінити його
  /// на власний у налаштуваннях (напр. щоб позначити, яку локацію квесту
  /// він означає) або натиснути "згенерувати новий" для довільного.
  Future<String> getInstanceId() async {
    final existing = await _storage.read(key: _instanceIdName);
    if (existing != null && existing.trim().isNotEmpty) return existing;
    final generated = await _defaultInstanceId();
    await _storage.write(key: _instanceIdName, value: generated);
    await _syncBackup();
    return generated;
  }

  /// Прив'язка "цей телефон → цей ідентифікатор" раніше губилась при
  /// кожному перевстановленні застосунку (генерувався новий випадковий),
  /// тож користувачу доводилось вручну її відновлювати. Android ID
  /// (`Settings.Secure.ANDROID_ID`) не потребує дозволів і лишається тим
  /// самим для застосунку на тому самому пристрої аж до скидання до
  /// заводських налаштувань — саме те, що потрібно для стабільного
  /// ідентифікатора "з коробки". Якщо він недоступний (дуже старий Android
  /// чи збій) — запасний варіант лишається випадковим, як і раніше.
  Future<String> _defaultInstanceId() async {
    final androidId = await DeviceIdService().getAndroidId();
    if (androidId != null && androidId.trim().isNotEmpty) {
      return _deviceInstanceIdFrom(androidId.trim());
    }
    return generateInstanceId();
  }

  Future<void> setInstanceId(String value) async {
    final v = value.trim();
    if (v.isEmpty) return;
    await _storage.write(key: _instanceIdName, value: v);
    await _syncBackup();
  }

  /// Людяний, легко відрізнюваний ідентифікатор без символів, які легко
  /// сплутати (0/O, 1/I) — випадковий (для ручного "перегенерувати").
  static String generateInstanceId() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    final suffix = List.generate(
      6,
      (_) => chars[rnd.nextInt(chars.length)],
    ).join();
    return 'OSTV-$suffix';
  }

  /// Той самий формат "OSTV-XXXXXX", але детермінований від [androidId] —
  /// однаковий вхід завжди дає однаковий вихід (FNV-1a, без залежності від
  /// вбудованого String.hashCode, який Dart не гарантує стабільним між
  /// запусками/версіями рантайму).
  static String _deviceInstanceIdFrom(String androidId) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final base = _fnv1a32(androidId);
    final buf = StringBuffer();
    for (var i = 0; i < 6; i++) {
      final mixed = _fnv1a32('$androidId#$i') ^ base;
      buf.write(chars[mixed % chars.length]);
    }
    return 'OSTV-$buf';
  }

  static int _fnv1a32(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  /// null/порожньо = автоматичний вибір за пріоритетом
  /// (провідний → bluetooth → вбудований).
  Future<String?> getPreferredInputDeviceId() =>
      _storage.read(key: _inputDeviceIdName);

  Future<void> setPreferredInputDeviceId(String? id) async {
    if (id == null || id.trim().isEmpty) {
      await _storage.delete(key: _inputDeviceIdName);
    } else {
      await _storage.write(key: _inputDeviceIdName, value: id);
    }
    await _syncBackup();
  }

  Future<String?> getPreferredOutputDeviceId() =>
      _storage.read(key: _outputDeviceIdName);

  Future<void> setPreferredOutputDeviceId(String? id) async {
    if (id == null || id.trim().isEmpty) {
      await _storage.delete(key: _outputDeviceIdName);
    } else {
      await _storage.write(key: _outputDeviceIdName, value: id);
    }
    await _syncBackup();
  }

  /// Автозапис кожної сесії квесту в .m4a на зовнішнє сховище — увімкнено
  /// за замовчуванням, вимикається вручну в налаштуваннях.
  Future<bool> getSessionRecordingEnabled() async {
    final v = await _storage.read(key: _sessionRecordingEnabledName);
    return v == null ? true : v == 'true';
  }

  Future<void> setSessionRecordingEnabled(bool value) async {
    await _storage.write(key: _sessionRecordingEnabledName, value: '$value');
    await _syncBackup();
  }

  /// Періодичний звіт статусу термінала у веб-панель. Типово ВИМКНЕНО:
  /// поки користувач сам не ввімкне й не вкаже адресу сервера, застосунок
  /// не надсилає нікуди нічого.
  Future<bool> getStatusReportingEnabled() async {
    final v = await _storage.read(key: _statusReportingEnabledName);
    return v == 'true';
  }

  Future<void> setStatusReportingEnabled(bool value) async {
    await _storage.write(key: _statusReportingEnabledName, value: '$value');
    await _syncBackup();
  }

  /// Адреса веб-панелі у вигляді `https://host:port`.
  Future<String?> getStatusServerUrl() =>
      _storage.read(key: _statusServerUrlName);

  Future<void> setStatusServerUrl(String value) async {
    final v = value.trim();
    if (v.isEmpty) {
      await _storage.delete(key: _statusServerUrlName);
    } else {
      await _storage.write(key: _statusServerUrlName, value: v);
    }
    await _syncBackup();
  }
}

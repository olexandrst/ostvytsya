import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../constants.dart';
import 'settings_store.dart';

/// Чи йде зараз квест — щоб це потрапляло у звіт статусу.
///
/// Свідомо найпростіше можливе рішення: один глобальний прапорець, який
/// виставляє екран квесту. Заводити заради двох булевих значень окрему
/// систему станів не варто.
class QuestActivity {
  static bool running = false;
  static String? characterName;

  static void started(String character) {
    running = true;
    characterName = character;
  }

  static void stopped() {
    running = false;
    characterName = null;
  }
}

/// Періодичний звіт статусу термінала у веб-панель.
///
/// Головна вимога — НЕ заважати. Звіт живе повністю збоку від квесту:
/// нічого не блокує, а будь-яка помилка (немає мережі, сервер лежить,
/// невірна адреса) тихо ігнорується. Максимум, що станеться в найгіршому
/// випадку, — панель не побачить цей термінал.
///
/// Типово вимкнено; вмикається в налаштуваннях разом з адресою сервера.
class StatusReporter {
  StatusReporter._();

  static final StatusReporter instance = StatusReporter._();

  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );

  /// Раз на 5 хвилин, як і домовлено з панеллю.
  static const interval = Duration(minutes: 5);

  /// Запит не має права висіти довше, ніж проміжок між звітами.
  static const _timeout = Duration(seconds: 20);

  final _settings = SettingsStore();
  Timer? _timer;
  bool _sending = false;

  /// Запустити періодичні звіти. Викликається на старті застосунку;
  /// повторний виклик просто перезапускає таймер (напр. після зміни
  /// налаштувань).
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(_reportSafely()));
    // Перший звіт — одразу, щоб термінал з'явився в панелі не через
    // п'ять хвилин після запуску.
    unawaited(_reportSafely());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Надіслати звіт «просто зараз» (напр. коли квест щойно почався чи
  /// завершився) — панель показує актуальніший стан, не чекаючи такту.
  void reportNow() => unawaited(_reportSafely());

  Future<void> _reportSafely() async {
    // Ловимо геть усе: збій звітування не має жодного стосунку до квесту й
    // не повинен його зачепити.
    try {
      await _report();
    } catch (_) {
      // Свідомо мовчки: мережа в парку ненадійна, і засмічувати транскрипт
      // квесту повідомленнями про невдалий звіт немає сенсу.
    }
  }

  Future<void> _report() async {
    if (_sending) return; // попередній звіт ще не завершився — пропускаємо такт
    if (!await _settings.getStatusReportingEnabled()) return;
    final base = normalizeServerUrl(await _settings.getStatusServerUrl());
    if (base == null) return;

    _sending = true;
    try {
      final payload = <String, dynamic>{
        'agent_id': await _settings.getInstanceId(),
        'quest_running': QuestActivity.running,
        'character': QuestActivity.characterName,
        'app_version': kAppVersion.isEmpty ? null : kAppVersion,
        ...await _collectTelemetry(),
      };

      await http
          .post(
            Uri.parse('$base/api/agents/status'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(_timeout);
    } finally {
      _sending = false;
    }
  }

  Future<Map<String, dynamic>> _collectTelemetry() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'collectTelemetry',
      );
      if (raw == null) return const {};
      return raw.map((key, value) => MapEntry('$key', value));
    } on PlatformException {
      return const {};
    } on MissingPluginException {
      return const {};
    }
  }

  /// Привести адресу до вигляду `https://host:port` без кінцевого слеша,
  /// або повернути null, якщо вона незрозуміла.
  ///
  /// Та сама перевірка використовується і в налаштуваннях, щоб користувач
  /// одразу бачив, що адреса негодяща, а не гадав, чому панель порожня.
  static String? normalizeServerUrl(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return null;
    final uri = Uri.tryParse(text);
    if (uri == null) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    if (uri.host.isEmpty) return null;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port';
  }
}

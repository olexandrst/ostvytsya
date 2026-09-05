import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../constants.dart';
import 'settings_store.dart';
import 'status_reporter.dart';

/// Повідомлення панелі про перемогу команди (квест пройдено до кінця).
///
/// Подія — річ разова й важлива, а мережа в парку ненадійна, тож просте
/// «вистрілив і забув» тут не годиться: подія спершу лягає в чергу на диску
/// (pending_wins.json у теці застосунку), а тоді відправляється — одразу і,
/// якщо не вдалось, на кожному наступному такті (раз на 5 хвилин) чи при
/// наступному старті застосунку, доки сервер не відповість 200. Сервер
/// розрізняє повтори за event_id (= ім'я сесії quest_<час>), тож дублів не
/// буває. Усе це — збоку від квесту: нічого не блокує, будь-яка помилка
/// тихо чекає наступної спроби. Працює завжди, коли в налаштуваннях
/// вказано адресу сервера.
class WinReporter {
  WinReporter._();

  static final WinReporter instance = WinReporter._();

  static const _flushInterval = Duration(minutes: 5);
  static const _timeout = Duration(seconds: 20);

  /// Стеля черги — на випадок, якщо сервера не буде тижнями.
  static const _maxPending = 200;

  final _settings = SettingsStore();
  Timer? _timer;
  bool _flushing = false;

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(_flushInterval, (_) => unawaited(_flushSafely()));
    // Одразу — раптом лишились недоставлені з попереднього запуску.
    unawaited(_flushSafely());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Зафіксувати перемогу й спробувати відправити негайно.
  Future<void> record({
    required String sessionName,
    required String characterId,
    required String characterName,
    required DateTime wonAt,
    required int durationS,
    required int runNumber,
  }) async {
    try {
      final pending = await _load();
      pending.add({
        'event_id': sessionName,
        'agent_id': await _settings.getInstanceId(),
        'character': characterName,
        'character_id': characterId,
        'won_at': wonAt.millisecondsSinceEpoch ~/ 1000,
        'duration_s': durationS,
        'run_number': runNumber,
        'app_version': kAppVersion.isEmpty ? null : kAppVersion,
      });
      while (pending.length > _maxPending) {
        pending.removeAt(0);
      }
      await _save(pending);
    } catch (_) {
      // Диск підвів — подія втрачена, але квест це не зачепить.
    }
    unawaited(_flushSafely());
  }

  Future<void> _flushSafely() async {
    try {
      await _flush();
    } catch (_) {
      // Наступний такт спробує знову.
    }
  }

  Future<void> _flush() async {
    if (_flushing) return;
    final base = StatusReporter.normalizeServerUrl(
      await _settings.getStatusServerUrl(),
    );
    if (base == null) return;
    _flushing = true;
    try {
      final pending = await _load();
      if (pending.isEmpty) return;
      final remaining = <Map<String, dynamic>>[];
      for (final event in pending) {
        var delivered = false;
        try {
          final resp = await http
              .post(
                Uri.parse('$base/api/agents/win'),
                headers: const {'Content-Type': 'application/json'},
                body: jsonEncode(event),
              )
              .timeout(_timeout);
          delivered = resp.statusCode == 200;
        } catch (_) {
          delivered = false;
        }
        if (!delivered) remaining.add(event);
      }
      if (remaining.length != pending.length) await _save(remaining);
    } finally {
      _flushing = false;
    }
  }

  Future<File> _file() async {
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, 'pending_wins.json'));
  }

  Future<List<Map<String, dynamic>>> _load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return [];
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return [];
      return [
        for (final e in raw)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<Map<String, dynamic>> pending) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(pending), flush: true);
  }
}

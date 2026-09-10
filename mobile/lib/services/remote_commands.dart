import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'settings_store.dart';
import 'status_reporter.dart';

/// Команди з веб-панелі для цього термінала — поки що одна: «перезапустити
/// квест». Телефон сам питає сервер раз на [interval] (лише поки відкрито
/// екран квесту) — жодного каналу від сервера до телефона немає, і це
/// навмисно: просто, без push-сервісів, і працює з будь-якої мережі.
///
/// Захист від зациклення: команда має час (годинник сервера), і телефон
/// виконує її лише якщо вона (1) не старша за [maxAge], (2) новіша за
/// останню виконану (час зберігається на диску — переживає перезапуск
/// застосунку) і (3) поставлена ПІСЛЯ старту цього процесу застосунку —
/// інакше телефон, який увімкнули через годину після натискання кнопки,
/// зупиняв би щойно початий квест. Після виконання шле серверу ack;
/// якщо ack не дійде — (2) все одно не дасть виконати команду вдруге.
///
/// Нічого тут не блокує квест: запит короткий (тайм-аут [_timeout]),
/// помилки мережі мовчки ігноруються до наступного опитування.
class RemoteCommands {
  RemoteCommands._();

  static final RemoteCommands instance = RemoteCommands._();

  /// Як часто питати сервер (вимога замовника — не довше 30 с).
  static const interval = Duration(seconds: 20);
  static const _timeout = Duration(seconds: 5);

  /// Команда, старша за це (за годинником сервера), — протухла.
  static const maxAge = Duration(minutes: 10);

  /// Момент старту цього процесу — команди, поставлені раніше, не наші.
  static final DateTime appStartedAt = DateTime.now();

  final _settings = SettingsStore();
  Timer? _timer;
  bool _busy = false;
  void Function()? _onRestart;
  double? _lastHandledRestartAt;
  bool _loaded = false;

  /// Почати опитування; [onRestart] викликається при свіжій команді.
  void start({required void Function() onRestart}) {
    _onRestart = onRestart;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(_pollSafely()));
    unawaited(_pollSafely());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _onRestart = null;
  }

  Future<void> _pollSafely() async {
    try {
      await _poll();
    } catch (_) {
      // Немає мережі, сервер спить, кривий JSON — до наступного разу.
    }
  }

  Future<void> _poll() async {
    if (_busy || _onRestart == null) return;
    _busy = true;
    try {
      final base = StatusReporter.normalizeServerUrl(
        await _settings.getStatusServerUrl(),
      );
      if (base == null) return;
      final id = await _settings.getInstanceId();
      final url = '$base/api/agents/${Uri.encodeComponent(id)}/commands';
      final resp = await http.get(Uri.parse(url)).timeout(_timeout);
      if (resp.statusCode != 200) return;
      final data = jsonDecode(utf8.decode(resp.bodyBytes));
      if (data is! Map) return;
      final rawAt = data['restart_at'];
      if (rawAt is! num) return;
      final restartAt = rawAt.toDouble();
      final phoneNow = DateTime.now().millisecondsSinceEpoch / 1000;
      final serverNow = (data['now'] as num?)?.toDouble() ?? phoneNow;

      // Свіжість — за годинником сервера (телефонний може бути кривий).
      if (serverNow - restartAt > maxAge.inSeconds) return;
      // Уже виконували цю (чи новішу) команду.
      final last = await _loadLastHandled();
      if (last != null && restartAt <= last) return;
      // Поставлена до старту цього процесу застосунку — не наша.
      final skew = serverNow - phoneNow;
      final startedAtServer =
          appStartedAt.millisecondsSinceEpoch / 1000 + skew;
      if (restartAt < startedAtServer) return;

      await _saveLastHandled(restartAt);
      _onRestart?.call();
      unawaited(_ack(base, id, restartAt));
    } finally {
      _busy = false;
    }
  }

  Future<void> _ack(String base, String id, double restartAt) async {
    try {
      await http
          .post(
            Uri.parse('$base/api/agents/${Uri.encodeComponent(id)}/commands/ack'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'restart_at': restartAt}),
          )
          .timeout(_timeout);
    } catch (_) {
      // Не дійшов — не страшно: повторно ту саму команду не виконаємо.
    }
  }

  // ── Пам'ять про виконані команди ──────────────────────────────────────

  Future<File> _stateFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, 'remote_commands.json'));
  }

  Future<double?> _loadLastHandled() async {
    if (_loaded) return _lastHandledRestartAt;
    _loaded = true;
    try {
      final file = await _stateFile();
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString());
      if (raw is Map && raw['last_restart_at'] is num) {
        _lastHandledRestartAt = (raw['last_restart_at'] as num).toDouble();
      }
    } catch (_) {
      // Пошкоджений файл — вважаємо, що нічого ще не виконували.
    }
    return _lastHandledRestartAt;
  }

  Future<void> _saveLastHandled(double ts) async {
    _lastHandledRestartAt = ts;
    _loaded = true;
    try {
      final file = await _stateFile();
      await file.writeAsString(jsonEncode({'last_restart_at': ts}), flush: true);
    } catch (_) {
      // Не записалось — у цьому процесі пам'ятаємо в змінній.
    }
  }
}

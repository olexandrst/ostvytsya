import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/character.dart';
import 'character_store.dart';
import 'settings_store.dart';
import 'status_reporter.dart';

/// Синхронізація персонажів між терміналами через веб-панель.
///
/// Принцип — «останній запис перемагає» за updated_at (unix-секунди):
/// раз на 5 хвилин (і одразу після кожної правки персонажа) телефон шле на
/// сервер ПОВНИЙ набір своїх персонажів, а у відповідь отримує ті, що на
/// сервері новіші, і зберігає їх собі. Повний набір щоразу — навмисно:
/// протокол виходить без станів і самовідновлюваним (рестарт сервера,
/// втрачені запити, довгий офлайн — усе лікується наступним вдалим тактом).
///
/// Як і звіти статусу, синхронізація живе повністю збоку від квесту: нічого
/// не блокує, а будь-яка помилка (зникла мережа при перемиканні wifi/4g,
/// сервер лежить) тихо ігнорується до наступного такту. Працює завжди, коли
/// в налаштуваннях вказано адресу сервера (окремого вмикача немає).
class CharacterSync {
  CharacterSync._();

  static final CharacterSync instance = CharacterSync._();

  static const interval = Duration(minutes: 5);

  /// Запит не має права висіти довше за такт; мережа в парку ненадійна.
  static const _timeout = Duration(seconds: 20);

  /// Захист від божевільної відповіді сервера — більше персонажів за раз
  /// просто не застосовуємо.
  static const _maxIncoming = 200;

  /// Той самий формат id, що генерує CharacterStore._slugify. Персонаж із
  /// «кривим» id від сервера не застосовується — id стає ім'ям файлу, і цю
  /// перевірку не можна пропускати.
  static final _idRe = RegExp(r'^[a-z0-9_-]{1,64}$');

  final _settings = SettingsStore();
  final _store = CharacterStore();
  Timer? _timer;
  bool _syncing = false;

  /// Запустити періодичну синхронізацію (виклик на старті застосунку).
  /// Повторний виклик просто перезапускає таймер.
  void start() {
    CharacterStore.onLocalChange = syncNow;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(_syncSafely()));
    // Перший такт — одразу: свіжовстановлений термінал підтягує персонажів,
    // не чекаючи 5 хвилин.
    unawaited(_syncSafely());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Синхронізуватися «просто зараз» (напр. одразу після збереження правки).
  void syncNow() => unawaited(_syncSafely());

  Future<void> _syncSafely() async {
    try {
      await _sync();
    } catch (_) {
      // Свідомо мовчки: наступний такт спробує знову.
    }
  }

  Future<void> _sync() async {
    if (_syncing) return; // попередній такт ще триває — не нашаровуємось
    final base = StatusReporter.normalizeServerUrl(
      await _settings.getStatusServerUrl(),
    );
    if (base == null) return;

    _syncing = true;
    try {
      final locals = await _store.listAll();
      final resp = await http
          .post(
            Uri.parse('$base/api/characters-sync'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'agent_id': await _settings.getInstanceId(),
              'characters': [for (final c in locals) c.toJson()],
            }),
          )
          .timeout(_timeout);
      if (resp.statusCode != 200) return;

      final data = jsonDecode(utf8.decode(resp.bodyBytes));
      if (data is! Map || data['characters'] is! List) return;
      final incoming = (data['characters'] as List).take(_maxIncoming);
      for (final raw in incoming) {
        // Один зіпсований персонаж не має ламати застосування решти.
        try {
          if (raw is! Map) continue;
          final remote = Character.fromJson(Map<String, dynamic>.from(raw));
          if (!_idRe.hasMatch(remote.id)) continue;
          final local = await _store.read(remote.id);
          if (local == null || remote.updatedAt > local.updatedAt) {
            await _store.save(remote, touch: false);
          }
        } catch (_) {
          continue;
        }
      }
    } finally {
      _syncing = false;
    }
  }
}

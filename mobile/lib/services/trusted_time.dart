import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../constants.dart';

/// Поточний час, отриманий з ІНТЕРНЕТУ, а не з годинника телефона.
///
/// Годинник телефона може переставити будь-хто (Налаштування → Дата й час),
/// тож для перевірки терміну дії квесту беремо час у великих публічних
/// сервісів через HTTPS: Google (заголовок `Date` відповіді
/// `generate_204` — тієї самої адреси, якою Android перевіряє інтернет) і
/// Cloudflare (`/cdn-cgi/trace`, поле `ts` — службовий час сервера). TLS
/// гарантує, що відповідь прийшла саме від них, а не від підмінного вузла чи
/// «портала авторизації» Wi-Fi у парку.
///
/// Обидва джерела опитуються ПАРАЛЕЛЬНО, перемагає перша коректна відповідь;
/// якщо жодне не відповіло за [_timeout] — часу немає (null), і це значить
/// «немає інтернету». Побічний ефект, теж на користь: якщо годинник телефона
/// виставлено дико неправильно, перевірка сертифікатів HTTPS не пройде, і
/// застосунок покаже «немає з'єднання», а не пропустить далі.
class TrustedTime {
  TrustedTime._();

  static const _timeout = Duration(seconds: 8);

  /// Усе раніше за це — явне сміття, а не реальний час.
  static final _earliestPlausible = DateTime.utc(2026, 1, 1);

  static final List<_TimeSource> _sources = [
    _TimeSource(
      'Google',
      Uri.parse('https://www.google.com/generate_204'),
      _fromDateHeader,
    ),
    _TimeSource(
      'Cloudflare',
      Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'),
      _fromCloudflareTrace,
    ),
  ];

  /// Точний поточний час (UTC) і звідки він, або null — інтернету немає чи
  /// жодне джерело не дало коректної відповіді.
  static Future<TrustedTimeReading?> now() {
    final completer = Completer<TrustedTimeReading?>();
    var pending = _sources.length;

    Future<void> ask(_TimeSource source) async {
      try {
        final reading = await source.read(_timeout);
        if (reading != null &&
            !reading.utc.isBefore(_earliestPlausible) &&
            !completer.isCompleted) {
          completer.complete(reading);
        }
      } catch (_) {
        // Немає мережі, TLS не пройшов, тайм-аут — пробуємо інші джерела.
      } finally {
        pending--;
        if (pending == 0 && !completer.isCompleted) completer.complete(null);
      }
    }

    for (final source in _sources) {
      unawaited(ask(source));
    }
    return completer.future;
  }

  static DateTime? _fromDateHeader(http.Response response) {
    final header = response.headers['date'];
    if (header == null || header.isEmpty) return null;
    try {
      return HttpDate.parse(header).toUtc();
    } catch (_) {
      return null;
    }
  }

  /// Тіло `/cdn-cgi/trace` — рядки `ключ=значення`, серед них
  /// `ts=1759312345.123` (секунди епохи). Немає поля — беремо заголовок `Date`.
  static DateTime? _fromCloudflareTrace(http.Response response) {
    for (final line in response.body.split('\n')) {
      if (!line.startsWith('ts=')) continue;
      final seconds = double.tryParse(line.substring(3).trim());
      if (seconds == null) break;
      return DateTime.fromMillisecondsSinceEpoch(
        (seconds * 1000).round(),
        isUtc: true,
      );
    }
    return _fromDateHeader(response);
  }
}

class TrustedTimeReading {
  final DateTime utc;

  /// Назва джерела — для журналу/діагностики.
  final String source;

  const TrustedTimeReading(this.utc, this.source);
}

class _TimeSource {
  final String name;
  final Uri uri;
  final DateTime? Function(http.Response response) parse;

  const _TimeSource(this.name, this.uri, this.parse);

  Future<TrustedTimeReading?> read(Duration timeout) async {
    final response = await http.get(uri).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 400) return null;
    final utc = parse(response);
    return utc == null ? null : TrustedTimeReading(utc, name);
  }
}

/// Результат перевірки терміну дії квесту.
enum ExpiryVerdict {
  /// Час з інтернету отримано, термін ще не минув.
  valid,

  /// Час з інтернету отримано, термін минув ([kQuestExpiresAtUtc]).
  expired,

  /// Час з інтернету отримати не вдалося.
  offline,
}

class QuestExpiry {
  QuestExpiry._();

  /// Чи минув термін дії на момент [utc].
  static bool isExpiredAt(DateTime utc) =>
      !utc.toUtc().isBefore(kQuestExpiresAtUtc);

  /// Перевірити термін дії за часом з інтернету.
  static Future<ExpiryVerdict> check() async {
    final reading = await TrustedTime.now();
    if (reading == null) return ExpiryVerdict.offline;
    return isExpiredAt(reading.utc)
        ? ExpiryVerdict.expired
        : ExpiryVerdict.valid;
  }
}

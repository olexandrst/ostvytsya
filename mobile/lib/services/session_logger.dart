import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../quest/transcript_line.dart';
import 'recordings_store.dart';

/// Спільна основа імені файлів однієї сесії: аудіо `quest_<час>.m4a` і
/// журнал `quest_<час>.txt` — щоб їх легко було зіставити.
String newSessionBaseName() {
  final ts = DateTime.now().toIso8601String().replaceAll(
    RegExp(r'[^0-9]'),
    '',
  );
  return 'quest_$ts';
}

/// Текстовий журнал однієї спроби квесту: кожен рядок транскрипту й
/// діагностики з таймкодом — у файл `Documents/Оствиця/logs/quest_<час>.txt`
/// (MediaStore, переживає видалення застосунку; на Android 9 і старіших —
/// тека застосунку поруч зі старими записами).
///
/// Пишеться ЗАВЖДИ, незалежно від того, чи ввімкнено запис аудіо: журнал
/// легкий, а для розбору проблем часто важливіший за звук. Дописуємо на
/// кожен рядок, а не наприкінці, — щоб раптове падіння застосунку не
/// забрало з собою те, що йому передувало.
///
/// Збій журналу ніколи не чіпає квест: усі помилки гасяться тут.
class SessionLogger {
  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );

  String? _uri;
  File? _file;
  bool _active = false;
  Future<void> _chain = Future<void>.value();

  bool get isActive => _active;

  /// Де лежить поточний журнал (`content://…` або шлях) — для транскрипту.
  String? get location => _uri ?? _file?.path;

  /// Почати журнал. [header] — службові рядки на початку (персонаж, версія
  /// тощо), [preamble] — останні події з фази очікування кодового слова, які
  /// передували пробудженню (що саме почув Vosk, який мікрофон обрано).
  Future<void> start(
    String baseName, {
    required List<String> header,
    List<TranscriptLine> preamble = const [],
  }) async {
    if (_active) return;
    final name = '$baseName.txt';
    String? uri;
    try {
      uri = await _channel.invokeMethod<String>('sessionLogCreate', {
        'name': name,
      });
    } on PlatformException {
      uri = null;
    } on MissingPluginException {
      uri = null;
    }
    if (uri != null) {
      _uri = uri;
      _file = null;
    } else {
      _uri = null;
      final dir = await RecordingsStore.legacyDirectory();
      _file = File('${dir.path}/$name');
    }
    _chain = Future<void>.value();
    _active = true;

    final buf = StringBuffer();
    for (final line in header) {
      buf.writeln(line);
    }
    if (preamble.isNotEmpty) {
      buf.writeln();
      buf.writeln('── Перед пробудженням (останні події очікування) ──');
      for (final line in preamble) {
        buf.writeln(line.logLine);
      }
    }
    buf.writeln();
    buf.writeln('── Сесія ──');
    _append(buf.toString());
  }

  void log(TranscriptLine line) {
    if (_active) _append('${line.logLine}\n');
  }

  void _append(String text) {
    final uri = _uri;
    final file = _file;
    _chain = _chain
        .then((_) async {
          if (uri != null) {
            await _channel.invokeMethod<bool>('sessionLogAppend', {
              'uri': uri,
              'text': text,
            });
          } else if (file != null) {
            await file.writeAsString(text, mode: FileMode.append, flush: true);
          }
        })
        .catchError((Object _) {
          // Журнал — допоміжний: його збій не має зачепити квест.
        });
  }

  /// Завершити журнал (дочекатись, поки все дописано).
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    await _chain;
    _uri = null;
    _file = null;
  }
}

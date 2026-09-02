import 'dart:io';

import 'package:flutter/services.dart';

import 'recordings_store.dart';

/// Один текстовий журнал сесії — у спільній теці (`content://`, переживає
/// видалення застосунку) або файл у теці застосунку (Android 9 і старіші).
class LogEntry {
  final String? uri;
  final File? file;
  final String displayName;
  final DateTime modified;
  final int sizeBytes;

  const LogEntry({
    this.uri,
    this.file,
    required this.displayName,
    required this.modified,
    required this.sizeBytes,
  });

  String get id => uri ?? file!.path;
}

/// Читання журналів сесій (SessionLogger) — дзеркало RecordingsStore для
/// текстових файлів у `Documents/Оствиця/logs`.
class SessionLogsStore {
  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );

  Future<List<LogEntry>> list() async {
    final entries = <LogEntry>[
      ...await _listFromMediaStore(),
      ...await _listLegacy(),
    ];
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  }

  Future<List<LogEntry>> _listFromMediaStore() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('listSessionLogs');
      if (raw == null) return const [];
      return raw.whereType<Map>().map((e) {
        return LogEntry(
          uri: '${e['uri']}',
          displayName: (e['name'] as String?) ?? 'Журнал квесту',
          modified: DateTime.fromMillisecondsSinceEpoch(
            (e['modified'] as int?) ?? 0,
          ),
          sizeBytes: (e['size'] as int?) ?? 0,
        );
      }).toList();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  Future<List<LogEntry>> _listLegacy() async {
    try {
      final dir = await RecordingsStore.legacyDirectory();
      final entries = <LogEntry>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.txt')) {
          final stat = await entity.stat();
          entries.add(
            LogEntry(
              file: entity,
              displayName: entity.uri.pathSegments.last,
              modified: stat.modified,
              sizeBytes: stat.size,
            ),
          );
        }
      }
      return entries;
    } catch (_) {
      return const [];
    }
  }

  /// Повний текст журналу; null — не вдалося прочитати.
  Future<String?> read(LogEntry entry) async {
    if (entry.file != null) {
      try {
        return await entry.file!.readAsString();
      } catch (_) {
        return null;
      }
    }
    try {
      return await _channel.invokeMethod<String>('readSessionLog', {
        'uri': entry.uri,
      });
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

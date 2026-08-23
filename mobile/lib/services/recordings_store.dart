import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Один записаний файл сесії квесту — або в спільній медіатеці пристрою
/// (`content://`, переживає видалення застосунку), або старий файл у теці
/// застосунку (лишився від попередніх версій).
class RecordingEntry {
  /// `content://…` для записів у медіатеці, інакше null.
  final String? uri;

  /// Звичайний файл — лише для старих записів у теці застосунку.
  final File? file;

  final String displayName;
  final DateTime modified;
  final int sizeBytes;

  const RecordingEntry({
    this.uri,
    this.file,
    required this.displayName,
    required this.modified,
    required this.sizeBytes,
  });

  /// Чи переживе цей запис видалення застосунку.
  bool get isPersistent => uri != null;

  /// Стабільний ключ для порівняння/дедуплікації в UI.
  String get id => uri ?? file!.path;
}

/// Доступ до записів сесій квесту.
///
/// Записи пишуться у СПІЛЬНУ медіатеку пристрою (`Music/Оствиця`) через
/// нативний MediaStore — саме тому вони переживають видалення застосунку.
/// Раніше вони лежали в теці застосунку (`Android/data/<pkg>/files`), яку
/// система стирає разом із застосунком, тож кожне перевстановлення APK
/// знищувало всю історію записів.
///
/// Старі записи з теки застосунку теж показуємо, поки вони там є, — щоб
/// нічого не зникло з очей одразу після оновлення.
class RecordingsStore {
  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );

  /// Запасна тека для Android 9 і старіших, де MediaStore ще не вміє
  /// RELATIVE_PATH. Там же лежать і старі записи попередніх версій.
  static Future<Directory> legacyDirectory() async {
    final base =
        await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/sessions');
    await dir.create(recursive: true);
    return dir;
  }

  Future<List<RecordingEntry>> list() async {
    final entries = <RecordingEntry>[
      ...await _listFromMediaStore(),
      ...await _listLegacy(),
    ];
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  }

  Future<List<RecordingEntry>> _listFromMediaStore() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>(
        'listSessionRecordings',
      );
      if (raw == null) return const [];
      return raw.whereType<Map>().map((e) {
        return RecordingEntry(
          uri: '${e['uri']}',
          displayName: (e['name'] as String?) ?? 'Запис квесту',
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

  Future<List<RecordingEntry>> _listLegacy() async {
    try {
      final dir = await legacyDirectory();
      final entries = <RecordingEntry>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.m4a')) {
          final stat = await entity.stat();
          entries.add(
            RecordingEntry(
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

  /// Звичайний файловий шлях до запису — потрібен і щоб «поділитись»
  /// (share_plus приймає файл, не `content://`), і щоб програти: MediaPlayer,
  /// на якому працює audioplayers, надійно грає файл, а `content://` через
  /// setDataSource(String) підхоплює не завжди. Тож для записів у медіатеці
  /// один раз копіюємо їх у кеш і далі використовуємо копію.
  Future<String?> localFilePath(RecordingEntry entry) async {
    if (entry.file != null) return entry.file!.path;
    final cached = _cachedCopies[entry.uri];
    if (cached != null && File(cached).existsSync()) return cached;
    try {
      final path = await _channel.invokeMethod<String>('copyRecordingToCache', {
        'uri': entry.uri,
        'name': entry.displayName,
      });
      if (path != null) _cachedCopies[entry.uri!] = path;
      return path;
    } on PlatformException {
      return null;
    }
  }

  /// Кеш «URI в медіатеці → копія у кеші застосунку», щоб не копіювати той
  /// самий запис щоразу при відтворенні.
  static final Map<String, String> _cachedCopies = {};
}

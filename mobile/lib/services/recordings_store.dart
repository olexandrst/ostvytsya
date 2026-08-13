import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Один записаний файл сесії квесту.
class RecordingEntry {
  final File file;
  final DateTime modified;
  final int sizeBytes;

  const RecordingEntry({
    required this.file,
    required this.modified,
    required this.sizeBytes,
  });
}

/// Спільний доступ до теки записів сесій ([SessionRecorder] пише туди,
/// [RecordingsScreen] звідти читає) — зовнішнє сховище застосунку
/// (`Android/data/<pkg>/files/sessions`), а не внутрішнє: не потребує
/// жодних дозволів (scoped storage), але дістатись до файлів можна й
/// напряму через файловий менеджер чи USB, без adb.
class RecordingsStore {
  static Future<Directory> sessionsDirectory() async {
    final base =
        await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/sessions');
    await dir.create(recursive: true);
    return dir;
  }

  Future<List<RecordingEntry>> list() async {
    final dir = await sessionsDirectory();
    final entries = <RecordingEntry>[];
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.m4a')) {
        final stat = await entity.stat();
        entries.add(
          RecordingEntry(
            file: entity,
            modified: stat.modified,
            sizeBytes: stat.size,
          ),
        );
      }
    }
    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  }
}

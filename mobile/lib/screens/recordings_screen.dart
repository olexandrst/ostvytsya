import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/recordings_store.dart';

/// Список записаних сесій квесту (SessionRecorder) — з розміром, датою і
/// можливістю "пошерити" файл через системне меню (месенджер, пошта, диск).
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key});

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  final _store = RecordingsStore();
  List<RecordingEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _store.list();
    if (mounted) setState(() => _entries = list);
  }

  Future<void> _share(RecordingEntry entry) async {
    await SharePlus.instance.share(
      ShareParams(files: [XFile(entry.file.path)]),
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}.${local.year} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String _formatSize(int bytes) {
    final mb = bytes / 1e6;
    return mb >= 1
        ? '${mb.toStringAsFixed(1)} МБ'
        : '${(bytes / 1e3).toStringAsFixed(0)} КБ';
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: const Text('Записи сесій')),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
          ? const Center(child: Text('Записів ще немає'))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: entries.length,
                itemBuilder: (context, i) {
                  final e = entries[i];
                  return ListTile(
                    leading: const Icon(Icons.graphic_eq),
                    title: Text(_formatDate(e.modified)),
                    subtitle: Text(_formatSize(e.sizeBytes)),
                    trailing: IconButton(
                      tooltip: 'Поділитись',
                      icon: const Icon(Icons.share),
                      onPressed: () => _share(e),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

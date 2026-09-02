import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/session_logs_store.dart';

/// Історія текстових журналів сесій (SessionLogger) — за зразком екрана
/// записів: список із датою й розміром, перегляд повного тексту та кнопка
/// «Копіювати» біля кожного журналу, щоб одним дотиком перекинути його в
/// месенджер чи чат для розбору проблем.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final _store = SessionLogsStore();
  List<LogEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await _store.list();
    if (mounted) setState(() => _entries = list);
  }

  Future<void> _copy(LogEntry entry) async {
    final text = await _store.read(entry);
    if (!mounted) return;
    if (text == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не вдалося прочитати журнал')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Скопійовано: ${entry.displayName}')),
    );
  }

  void _open(LogEntry entry) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => LogViewScreen(entry: entry)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: const Text('Журнали сесій')),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
          ? const Center(child: Text('Журналів ще немає'))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: entries.length,
                itemBuilder: (context, i) {
                  final e = entries[i];
                  return ListTile(
                    leading: const Icon(Icons.description_outlined, size: 32),
                    title: Text(formatLogDate(e.modified)),
                    subtitle: Text(
                      '${e.displayName} · ${formatLogSize(e.sizeBytes)}',
                    ),
                    trailing: IconButton(
                      tooltip: 'Копіювати',
                      icon: const Icon(Icons.copy),
                      onPressed: () => _copy(e),
                    ),
                    onTap: () => _open(e),
                  );
                },
              ),
            ),
    );
  }
}

/// Повний текст одного журналу з кнопкою «Копіювати» в заголовку.
class LogViewScreen extends StatefulWidget {
  const LogViewScreen({super.key, required this.entry});

  final LogEntry entry;

  @override
  State<LogViewScreen> createState() => _LogViewScreenState();
}

class _LogViewScreenState extends State<LogViewScreen> {
  final _store = SessionLogsStore();
  String? _text;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final text = await _store.read(widget.entry);
    if (mounted) {
      setState(() {
        _text = text;
        _loading = false;
      });
    }
  }

  Future<void> _copy() async {
    final text = _text;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Скопійовано в буфер обміну')));
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry.displayName),
        actions: [
          IconButton(
            tooltip: 'Копіювати',
            icon: const Icon(Icons.copy),
            onPressed: text == null ? null : _copy,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : text == null
          ? const Center(child: Text('Не вдалося прочитати журнал'))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
    );
  }
}

String formatLogDate(DateTime dt) {
  final local = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.day)}.${two(local.month)}.${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}

String formatLogSize(int bytes) {
  if (bytes >= 1000000) return '${(bytes / 1e6).toStringAsFixed(1)} МБ';
  return '${(bytes / 1e3).toStringAsFixed(bytes < 1000 ? 1 : 0)} КБ';
}

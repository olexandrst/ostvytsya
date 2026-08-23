import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../services/recordings_store.dart';

/// Список записаних сесій квесту (SessionRecorder) — з розміром, датою,
/// прослуховуванням прямо в застосунку та можливістю "пошерити" файл через
/// системне меню (месенджер, пошта, диск).
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key});

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  final _store = RecordingsStore();
  final _player = AudioPlayer();
  List<RecordingEntry>? _entries;

  String? _playingPath;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  StreamSubscription<void>? _completeSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void initState() {
    super.initState();
    _load();
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playingPath = null;
          _isPlaying = false;
          _position = Duration.zero;
        });
      }
    });
    _positionSub = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _durationSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _isPlaying = s == PlayerState.playing);
    });
  }

  @override
  void dispose() {
    _completeSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Без цього дозволу система віддає лише записи, створені ПОТОЧНИМ
    // встановленням застосунку — історія від попередніх версій (заради якої
    // записи й перенесено у спільну медіатеку) була б невидимою.
    await Permission.audio.request();
    final list = await _store.list();
    if (mounted) setState(() => _entries = list);
  }

  Future<void> _togglePlay(RecordingEntry entry) async {
    if (_playingPath == entry.id) {
      if (_isPlaying) {
        await _player.pause();
      } else {
        await _player.resume();
      }
      return;
    }
    // Для записів у медіатеці це копія в кеші (робиться один раз) — див.
    // RecordingsStore.localFilePath.
    final path = await _store.localFilePath(entry);
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не вдалося відкрити запис')),
        );
      }
      return;
    }
    if (!mounted) return;
    setState(() {
      _playingPath = entry.id;
      _position = Duration.zero;
      _duration = Duration.zero;
    });
    await _player.play(DeviceFileSource(path));
  }

  Future<void> _share(RecordingEntry entry) async {
    final path = await _store.localFilePath(entry);
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не вдалося підготувати файл')),
        );
      }
      return;
    }
    await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
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

  String _formatDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
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
                  final isCurrent = _playingPath == e.id;
                  final playing = isCurrent && _isPlaying;
                  return Column(
                    children: [
                      ListTile(
                        leading: IconButton(
                          tooltip: playing ? 'Пауза' : 'Відтворити',
                          icon: Icon(
                            playing ? Icons.pause_circle : Icons.play_circle,
                          ),
                          iconSize: 36,
                          onPressed: () => _togglePlay(e),
                        ),
                        title: Text(_formatDate(e.modified)),
                        subtitle: Text(_formatSize(e.sizeBytes)),
                        trailing: IconButton(
                          tooltip: 'Поділитись',
                          icon: const Icon(Icons.share),
                          onPressed: () => _share(e),
                        ),
                      ),
                      if (isCurrent)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Slider(
                                  value: _duration.inMilliseconds > 0
                                      ? _position.inMilliseconds
                                            .clamp(
                                              0,
                                              _duration.inMilliseconds,
                                            )
                                            .toDouble()
                                      : 0,
                                  max: _duration.inMilliseconds > 0
                                      ? _duration.inMilliseconds.toDouble()
                                      : 1,
                                  onChanged: (v) => _player.seek(
                                    Duration(milliseconds: v.round()),
                                  ),
                                ),
                              ),
                              Text(
                                '${_formatDuration(_position)} / '
                                '${_formatDuration(_duration)}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
    );
  }
}

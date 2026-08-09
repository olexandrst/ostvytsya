import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vosk_flutter_service/vosk_flutter_service.dart';

import '../constants.dart';
import '../models/character.dart';
import '../services/character_store.dart';
import '../services/crash_log.dart';
import 'character_edit_screen.dart';
import 'quest_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _store = CharacterStore();
  final _crashLog = CrashLogService();
  List<Character>? _characters;

  bool _voskReady = false;
  String? _voskError;
  String _voskStatus = 'Перевіряю голосову модель Vosk...';

  @override
  void initState() {
    super.initState();
    _load();
    _preloadVoskModel();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkLastCrash());
  }

  Future<void> _load() async {
    await _store.ensureDefaults();
    final list = await _store.listAll();
    if (mounted) setState(() => _characters = list);
  }

  /// Завантажити (або підхопити з кешу) модель Vosk ще ДО того, як
  /// відкриється будь-який квест — щоб не було мовчазного зависання на
  /// екрані квесту, поки модель вперше качається з мережі. Доки це не
  /// завершиться, список персонажів і старт квесту заблоковані.
  Future<void> _preloadVoskModel() async {
    try {
      final modelName = kVoskModelUrl.split('/').last.replaceAll('.zip', '');
      final alreadyLoaded = await ModelLoader().isModelAlreadyLoaded(modelName);
      if (!alreadyLoaded && mounted) {
        setState(
          () => _voskStatus =
              'Завантажую голосову модель Vosk (лише один раз, потім '
              'кешується на пристрої)...',
        );
      }
      await ModelLoader().loadFromNetwork(kVoskModelUrl);
      if (mounted) setState(() => _voskReady = true);
    } catch (e) {
      if (mounted) {
        setState(() => _voskError = 'Не вдалося завантажити модель Vosk: $e');
      }
    }
  }

  Future<void> _checkLastCrash() async {
    final javaLog = await _crashLog.readLastCrash();
    final exitReason = await _crashLog.readLastExitReason();

    final parts = <String>[];
    if (exitReason != null && exitReason.trim().isNotEmpty) {
      parts.add('== Причина виходу процесу (система) ==\n$exitReason');
    }
    if (javaLog != null && javaLog.trim().isNotEmpty) {
      parts.add('== Необроблений Java/Kotlin-виняток ==\n$javaLog');
    }
    if (parts.isEmpty || !mounted) return;
    final log = parts.join('\n\n');

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Застосунок нещодавно аварійно завершився'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              log,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: log));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Скопійовано в буфер обміну')),
              );
            },
            child: const Text('Копіювати'),
          ),
          TextButton(
            onPressed: () {
              _crashLog.clearLastCrash();
              _crashLog.acknowledgeExitReason();
              Navigator.pop(ctx);
            },
            child: const Text('Закрити'),
          ),
        ],
      ),
    );
  }

  Future<void> _openEdit({Character? character}) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            CharacterEditScreen(character: character, store: _store),
      ),
    );
    if (changed == true) _load();
  }

  Future<void> _clone(Character c) async {
    final newId = await _store.uniqueIdFromName('${c.displayName} копія');
    final clone = c.copyWith(
      id: newId,
      displayName: '${c.displayName} (копія)',
    );
    await _store.save(clone);
    _load();
  }

  Future<void> _delete(Character c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Видалити персонажа?'),
        content: Text('«${c.displayName}» буде видалено безповоротно.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Скасувати'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Видалити'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _store.delete(c.id);
      _load();
    }
  }

  void _start(Character c) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => QuestScreen(character: c)),
    );
  }

  Widget _buildVoskGate() {
    if (_voskError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(_voskError!, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _voskError = null;
                    _voskStatus = 'Перевіряю голосову модель Vosk...';
                  });
                  _preloadVoskModel();
                },
                child: const Text('Спробувати ще раз'),
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 24),
            Text(_voskStatus, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final characters = _characters;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Оствиця — квести'),
        actions: [
          IconButton(
            tooltip: 'Налаштування',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: !_voskReady
          ? _buildVoskGate()
          : characters == null
          ? const Center(child: CircularProgressIndicator())
          : characters.isEmpty
          ? const Center(child: Text('Персонажів ще немає — натисни «+»'))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: characters.length,
              itemBuilder: (context, i) {
                final c = characters[i];
                final providerLabel = c.provider == 'google'
                    ? 'Gemini'
                    : 'OpenAI';
                final voiceLabel = c.provider == 'google'
                    ? c.voice
                    : c.openaiVoice;
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: ListTile(
                    leading: CircleAvatar(
                      child: Text(
                        c.displayName.isNotEmpty ? c.displayName[0] : '?',
                      ),
                    ),
                    title: Text(c.displayName),
                    subtitle: Text(
                      '$providerLabel · голос $voiceLabel\n'
                      'кодове «${c.effectiveWakeWords.join(', ')}» · перемога «${c.winWord}»',
                    ),
                    isThreeLine: true,
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        switch (v) {
                          case 'edit':
                            _openEdit(character: c);
                            break;
                          case 'clone':
                            _clone(c);
                            break;
                          case 'delete':
                            _delete(c);
                            break;
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Редагувати')),
                        PopupMenuItem(value: 'clone', child: Text('Клонувати')),
                        PopupMenuItem(value: 'delete', child: Text('Видалити')),
                      ],
                    ),
                    onTap: () => _start(c),
                  ),
                );
              },
            ),
      floatingActionButton: !_voskReady
          ? null
          : FloatingActionButton(
              tooltip: 'Новий персонаж',
              onPressed: () => _openEdit(),
              child: const Icon(Icons.add),
            ),
    );
  }
}

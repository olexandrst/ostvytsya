import 'package:flutter/material.dart';

import '../models/character.dart';
import '../services/character_store.dart';
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
  List<Character>? _characters;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _store.ensureDefaults();
    final list = await _store.listAll();
    if (mounted) setState(() => _characters = list);
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
      body: characters == null
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
                      '$providerLabel · голос $voiceLabel · слово «${c.winWord}»',
                    ),
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
      floatingActionButton: FloatingActionButton(
        tooltip: 'Новий персонаж',
        onPressed: () => _openEdit(),
        child: const Icon(Icons.add),
      ),
    );
  }
}

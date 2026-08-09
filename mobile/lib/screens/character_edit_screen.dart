import 'package:flutter/material.dart';

import '../constants.dart';
import '../models/character.dart';
import '../services/character_store.dart';

class CharacterEditScreen extends StatefulWidget {
  final Character? character;
  final CharacterStore store;

  const CharacterEditScreen({
    super.key,
    required this.character,
    required this.store,
  });

  @override
  State<CharacterEditScreen> createState() => _CharacterEditScreenState();
}

class _CharacterEditScreenState extends State<CharacterEditScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _promptCtrl;
  late final TextEditingController _winWordCtrl;
  late String _provider;
  late String _openaiVoice;
  late String _geminiVoice;
  late double _speechSpeed;
  bool _saving = false;

  bool get _isNew => widget.character == null;

  @override
  void initState() {
    super.initState();
    final c = widget.character;
    _nameCtrl = TextEditingController(text: c?.displayName ?? '');
    _promptCtrl = TextEditingController(text: c?.systemPrompt ?? '');
    _winWordCtrl = TextEditingController(text: c?.winWord ?? kDefaultWinWord);
    _provider = c?.provider ?? 'google';
    _openaiVoice = (c?.openaiVoice.isNotEmpty ?? false)
        ? c!.openaiVoice
        : kDefaultOpenAiVoice;
    _geminiVoice = (c?.voice.isNotEmpty ?? false)
        ? c!.voice
        : kDefaultGeminiVoice;
    _speechSpeed = c?.speechSpeed ?? kDefaultSpeechSpeed;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _promptCtrl.dispose();
    _winWordCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final id =
          widget.character?.id ??
          await widget.store.uniqueIdFromName(_nameCtrl.text);
      final character = Character(
        id: id,
        displayName: _nameCtrl.text.trim(),
        provider: _provider,
        openaiVoice: _openaiVoice,
        voice: _geminiVoice,
        speechSpeed: _speechSpeed,
        systemPrompt: _promptCtrl.text.trim(),
        winWord: _winWordCtrl.text.trim().isEmpty
            ? kDefaultWinWord
            : _winWordCtrl.text.trim(),
      );
      await widget.store.save(character);
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Новий персонаж' : 'Редагувати персонажа'),
        actions: [
          IconButton(
            icon: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check),
            onPressed: _saving ? null : _save,
            tooltip: 'Зберегти',
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(labelText: 'Назва персонажа'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? "Вкажи назву" : null,
            ),
            const SizedBox(height: 16),
            const Text(
              'Провайдер голосу',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'google', label: Text('Google Gemini')),
                ButtonSegment(value: 'openai', label: Text('OpenAI')),
              ],
              selected: {_provider},
              onSelectionChanged: (s) => setState(() => _provider = s.first),
            ),
            const SizedBox(height: 16),
            if (_provider == 'google') ...[
              DropdownButtonFormField<String>(
                initialValue: _geminiVoice,
                decoration: const InputDecoration(labelText: 'Голос (Gemini)'),
                items: kGeminiVoiceLabels.entries
                    .map(
                      (e) => DropdownMenuItem(
                        value: e.key,
                        child: Text('${e.key} — ${e.value}'),
                      ),
                    )
                    .toList(),
                onChanged: (v) =>
                    setState(() => _geminiVoice = v ?? _geminiVoice),
              ),
            ] else ...[
              DropdownButtonFormField<String>(
                initialValue: _openaiVoice,
                decoration: const InputDecoration(labelText: 'Голос (OpenAI)'),
                items: kOpenAiVoices
                    .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                    .toList(),
                onChanged: (v) =>
                    setState(() => _openaiVoice = v ?? _openaiVoice),
              ),
              const SizedBox(height: 12),
              Text('Швидкість мовлення: ${_speechSpeed.toStringAsFixed(2)}x'),
              Slider(
                value: _speechSpeed,
                min: 0.25,
                max: 2.0,
                divisions: 35,
                label: '${_speechSpeed.toStringAsFixed(2)}x',
                onChanged: (v) => setState(() => _speechSpeed = v),
              ),
            ],
            const SizedBox(height: 16),
            TextFormField(
              controller: _winWordCtrl,
              decoration: const InputDecoration(
                labelText: 'Таємне слово (перемога)',
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _promptCtrl,
              decoration: const InputDecoration(
                labelText: 'Промпт персонажа (сценарій, загадки, характер)',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
              maxLines: 16,
              minLines: 8,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Вкажи промпт персонажа'
                  : null,
            ),
            const SizedBox(height: 8),
            const Text(
              'Мовні й акторські правила (українська без акценту, жива подача) '
              'додаються автоматично до кожного персонажа — їх не треба писати тут.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

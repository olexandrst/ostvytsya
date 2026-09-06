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
  late final TextEditingController _wakeWordsCtrl;
  late final TextEditingController _stopWordsCtrl;
  late final TextEditingController _idleTimeoutCtrl;
  late final TextEditingController _answerWaitCtrl;
  late String _provider;
  late String _openaiVoice;
  late String _geminiVoice;
  late double _speechSpeed;
  late bool _wakeOnVoice;
  late bool _contextCompression;
  bool _saving = false;

  bool get _isNew => widget.character == null;

  @override
  void initState() {
    super.initState();
    final c = widget.character;
    _nameCtrl = TextEditingController(text: c?.displayName ?? '');
    _promptCtrl = TextEditingController(text: c?.systemPrompt ?? '');
    _winWordCtrl = TextEditingController(text: c?.winWord ?? kDefaultWinWord);
    _wakeWordsCtrl = TextEditingController(
      text: (c?.wakeWords ?? const []).join(', '),
    );
    _stopWordsCtrl = TextEditingController(
      text: (c?.stopWords ?? const []).join(', '),
    );
    _idleTimeoutCtrl = TextEditingController(
      text: c?.inactivityTimeoutS?.toString() ?? '',
    );
    _answerWaitCtrl = TextEditingController(
      text: (c?.answerWaitS ?? kDefaultAnswerWaitS).toString(),
    );
    _wakeOnVoice = c?.wakeOnVoice ?? false;
    _contextCompression = c?.contextCompression ?? true;
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
    _wakeWordsCtrl.dispose();
    _stopWordsCtrl.dispose();
    _idleTimeoutCtrl.dispose();
    _answerWaitCtrl.dispose();
    super.dispose();
  }

  int? _optionalInt(TextEditingController ctrl) {
    final raw = ctrl.text.trim();
    return raw.isEmpty ? null : int.tryParse(raw);
  }

  String? _validateOptionalInt(String? v, int min) {
    final t = (v ?? '').trim();
    if (t.isEmpty) return null;
    final n = int.tryParse(t);
    return (n == null || n < min) ? 'Ціле число від $min' : null;
  }

  List<String> _splitWords(String raw) => raw
      .split(',')
      .map((w) => w.trim())
      .where((w) => w.isNotEmpty)
      .toList();

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
        // Порожньо — дозволено: персонаж без слова перемоги (екскурсія,
        // зазивайло) завершує сесію словом гостей чи тайм-аутом тиші.
        winWord: _winWordCtrl.text.trim(),
        wakeWords: _splitWords(_wakeWordsCtrl.text),
        stopWords: _splitWords(_stopWordsCtrl.text),
        wakeOnVoice: _wakeOnVoice,
        inactivityTimeoutS: _optionalInt(_idleTimeoutCtrl),
        answerWaitS: _optionalInt(_answerWaitCtrl) ?? kDefaultAnswerWaitS,
        contextCompression: _contextCompression,
      );
      await widget.store.save(character);
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  bool get _hasDefault =>
      !_isNew && CharacterStore.hasDefault(widget.character!.id);

  /// Повернути персонажа з комплекту до типової версії (сценарій, голос,
  /// кодові слова, поведінка сесії) — усі правки на цьому й інших
  /// терміналах перекриваються, бо скидання синхронізується як нова правка.
  Future<void> _resetToDefault() async {
    final c = widget.character!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Скинути до типового?'),
        content: Text(
          'Персонаж «${c.displayName}» повернеться до версії з комплекту '
          'застосунку: промпт, голос, кодові слова й налаштування сесії. '
          'Усі правки буде втрачено — і на інших терміналах теж (скидання '
          'синхронізується як звичайна правка).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Скасувати'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Скинути'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      final fresh = await widget.store.resetToDefault(c.id);
      if (!mounted) return;
      if (fresh == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Типової версії для цього персонажа немає.')),
        );
        return;
      }
      Navigator.pop(context, true);
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
            ],
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
            const SizedBox(height: 16),
            TextFormField(
              controller: _wakeWordsCtrl,
              decoration: const InputDecoration(
                labelText: 'Кодове слово(а) активації',
                helperText:
                    'Через кому. Персонаж мовчки слухає, поки не почує одне '
                    'з них — лише тоді стартує квест. Якщо порожньо — '
                    'використається назва персонажа.',
                helperMaxLines: 3,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Прокидатись від будь-якого голосу'),
              subtitle: const Text(
                'Для зазивайла біля входу: озивається, щойно поруч '
                'заговорять, — кодове слово не потрібне.',
              ),
              value: _wakeOnVoice,
              onChanged: (v) => setState(() => _wakeOnVoice = v),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _winWordCtrl,
              decoration: const InputDecoration(
                labelText: 'Таємне слово (перемога)',
                helperText:
                    'Персонаж називає його в кінці — це перемога й кінець '
                    'квесту. Порожньо — квест не завершується словом '
                    'персонажа (екскурсія, зазивайло).',
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _stopWordsCtrl,
              decoration: const InputDecoration(
                labelText: 'Слова завершення від гостей',
                helperText:
                    'Через кому. Почувши одне з них від гравців, персонаж '
                    'прощається і сесія закривається (напр. «Каліпсо» для '
                    'екскурсії).',
                helperMaxLines: 3,
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _idleTimeoutCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Тайм-аут тиші, секунд',
                helperText:
                    'Скільки тиші завершують сесію. Порожньо — 30 хвилин. '
                    'Зазивайлу вистачить ~60, квесту з пошуком — 600+.',
                helperMaxLines: 3,
              ),
              validator: (v) => _validateOptionalInt(v, 10),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _answerWaitCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Час очікування відповіді, секунд',
                helperText:
                    'Скільки персонаж мовчки слухає людей після своєї '
                    'репліки, перш ніж продовжити самому (повторити '
                    'питання, підказати, вести розповідь далі). Типово 8. '
                    '0 — без обмеження.',
                helperMaxLines: 4,
              ),
              validator: (v) => _validateOptionalInt(v, 0),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Стискати контекст розмови (економія)'),
              subtitle: const Text(
                'Персонаж пам\'ятає лише останні ~8–15 хвилин розмови, зате '
                'довга сесія коштує у 2–3 рази дешевше. Вимкни для квестів, '
                'де треба пам\'ятати все сказане від початку (Повітруля веде '
                'лік знайдених слів). Діє з наступного запуску квесту.',
              ),
              isThreeLine: true,
              value: _contextCompression,
              onChanged: (v) => setState(() => _contextCompression = v),
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
            if (_hasDefault) ...[
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _saving ? null : _resetToDefault,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Скинути до типового'),
              ),
              const SizedBox(height: 4),
              const Text(
                'Повернути версію з комплекту застосунку (промпт, голос, '
                'кодові слова, налаштування сесії). Правки на всіх '
                'терміналах буде перекрито.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

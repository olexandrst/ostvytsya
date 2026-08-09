import 'package:flutter/material.dart';

import '../services/settings_store.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _store = SettingsStore();
  final _geminiCtrl = TextEditingController();
  final _openaiCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _showGemini = false;
  bool _showOpenAi = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final gemini = await _store.getGeminiApiKey();
    final openai = await _store.getOpenAiApiKey();
    _geminiCtrl.text = gemini ?? '';
    _openaiCtrl.text = openai ?? '';
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await _store.setGeminiApiKey(_geminiCtrl.text);
    await _store.setOpenAiApiKey(_openaiCtrl.text);
    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ключі збережено на пристрої')),
      );
    }
  }

  @override
  void dispose() {
    _geminiCtrl.dispose();
    _openaiCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Налаштування'),
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Ключі API зберігаються лише на цьому пристрої (захищене '
                  'сховище). Жодного сервера й логіна — застосунок звертається '
                  'до Gemini/OpenAI напряму з цими ключами.',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _geminiCtrl,
                  obscureText: !_showGemini,
                  decoration: InputDecoration(
                    labelText: 'Gemini API ключ',
                    helperText: 'aistudio.google.com/apikey',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _showGemini ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () =>
                          setState(() => _showGemini = !_showGemini),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _openaiCtrl,
                  obscureText: !_showOpenAi,
                  decoration: InputDecoration(
                    labelText: 'OpenAI API ключ',
                    helperText: 'platform.openai.com/api-keys',
                    suffixIcon: IconButton(
                      icon: Icon(
                        _showOpenAi ? Icons.visibility_off : Icons.visibility,
                      ),
                      onPressed: () =>
                          setState(() => _showOpenAi = !_showOpenAi),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

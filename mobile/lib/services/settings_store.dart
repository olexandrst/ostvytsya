import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Ключі API (Gemini, OpenAI), збережені на пристрої. Жодного логіна — лише
/// ці два ключі, введені користувачем у налаштуваннях.
class SettingsStore {
  static const _geminiKeyName = 'gemini_api_key';
  static const _openaiKeyName = 'openai_api_key';

  final _storage = const FlutterSecureStorage();

  Future<String?> getGeminiApiKey() => _storage.read(key: _geminiKeyName);
  Future<String?> getOpenAiApiKey() => _storage.read(key: _openaiKeyName);

  Future<void> setGeminiApiKey(String value) async {
    final v = value.trim();
    if (v.isEmpty) {
      await _storage.delete(key: _geminiKeyName);
    } else {
      await _storage.write(key: _geminiKeyName, value: v);
    }
  }

  Future<void> setOpenAiApiKey(String value) async {
    final v = value.trim();
    if (v.isEmpty) {
      await _storage.delete(key: _openaiKeyName);
    } else {
      await _storage.write(key: _openaiKeyName, value: v);
    }
  }
}

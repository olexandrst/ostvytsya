import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Ключі API (Gemini, OpenAI) і локальні налаштування пристрою (жодного
/// логіна — усе зберігається лише на цьому пристрої).
class SettingsStore {
  static const _geminiKeyName = 'gemini_api_key';
  static const _openaiKeyName = 'openai_api_key';
  static const _instanceIdName = 'app_instance_id';
  static const _inputDeviceIdName = 'preferred_input_device_id';
  static const _outputDeviceIdName = 'preferred_output_device_id';

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

  /// Ідентифікатор цього примірника застосунку — за замовчуванням
  /// згенерований випадково при першому зверненні, але користувач може
  /// замінити його на власний у налаштуваннях (напр. щоб позначити, який
  /// телефон/локацію квесту він означає).
  Future<String> getInstanceId() async {
    final existing = await _storage.read(key: _instanceIdName);
    if (existing != null && existing.trim().isNotEmpty) return existing;
    final generated = generateInstanceId();
    await _storage.write(key: _instanceIdName, value: generated);
    return generated;
  }

  Future<void> setInstanceId(String value) async {
    final v = value.trim();
    if (v.isEmpty) return;
    await _storage.write(key: _instanceIdName, value: v);
  }

  /// Людяний, легко відрізнюваний ідентифікатор без символів, які легко
  /// сплутати (0/O, 1/I).
  static String generateInstanceId() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    final suffix = List.generate(
      6,
      (_) => chars[rnd.nextInt(chars.length)],
    ).join();
    return 'OSTV-$suffix';
  }

  /// null/порожньо = автоматичний вибір за пріоритетом
  /// (провідний → bluetooth → вбудований).
  Future<String?> getPreferredInputDeviceId() =>
      _storage.read(key: _inputDeviceIdName);

  Future<void> setPreferredInputDeviceId(String? id) async {
    if (id == null || id.trim().isEmpty) {
      await _storage.delete(key: _inputDeviceIdName);
    } else {
      await _storage.write(key: _inputDeviceIdName, value: id);
    }
  }

  Future<String?> getPreferredOutputDeviceId() =>
      _storage.read(key: _outputDeviceIdName);

  Future<void> setPreferredOutputDeviceId(String? id) async {
    if (id == null || id.trim().isEmpty) {
      await _storage.delete(key: _outputDeviceIdName);
    } else {
      await _storage.write(key: _outputDeviceIdName, value: id);
    }
  }
}

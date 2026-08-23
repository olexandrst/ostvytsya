import 'package:flutter/services.dart';

/// Доступ до файлів, які мають пережити видалення застосунку: резервна
/// копія налаштувань і завантажена модель Vosk.
///
/// Усе лежить у спільній теці `Documents/Оствиця` (нативний MediaStore,
/// [PersistentFiles.kt]) — система не стирає її разом із застосунком.
/// Android Auto Backup тут не помічник: він відновлює дані лише при
/// встановленні через Play Store чи під час первинного налаштування
/// пристрою, а APK, встановлений збоку, відновлення не запускає.
class PersistentBackup {
  static const _channel = MethodChannel(
    'com.ostvytsya.ostvytsya_quest/foreground',
  );

  /// Зберегти всі налаштування (JSON) у зашифрованому вигляді.
  Future<bool> saveSettings(String json) async {
    try {
      final ok = await _channel.invokeMethod<bool>('backupSettings', {
        'json': json,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Прочитати збережені налаштування, або null, якщо копії немає.
  Future<String?> loadSettings() async {
    try {
      return await _channel.invokeMethod<String>('restoreSettings');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<bool> fileExists(String name) async {
    try {
      final ok = await _channel.invokeMethod<bool>('persistentFileExists', {
        'name': name,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Покласти локальний файл у сховище. Копіювання відбувається НАТИВНО,
  /// потоком: архів моделі Vosk важить 140+ МБ, і тягти такі обсяги через
  /// канал платформи було б і повільно, і небезпечно для пам'яті.
  Future<bool> importFile(String name, String sourcePath) async {
    try {
      final ok = await _channel.invokeMethod<bool>('persistentFileImport', {
        'name': name,
        'sourcePath': sourcePath,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Дістати файл зі сховища у локальний шлях.
  Future<bool> exportFile(String name, String targetPath) async {
    try {
      final ok = await _channel.invokeMethod<bool>('persistentFileExport', {
        'name': name,
        'targetPath': targetPath,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

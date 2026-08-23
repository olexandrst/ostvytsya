import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/character.dart';

/// Локальне сховище персонажів: по одному JSON-файлу на персонажа в теці
/// документів застосунку (мобільний аналог characters/*.yaml). Жодного
/// сервера — усе на пристрої.
class CharacterStore {
  static const _defaultIds = ['domovychok', 'vodyanyk', 'povitrulya'];

  Directory? _dir;

  Future<Directory> _charactersDir() async {
    if (_dir != null) return _dir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'characters'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dir = dir;
    return dir;
  }

  File _fileFor(Directory dir, String id) => File(p.join(dir.path, '$id.json'));

  /// Скопіювати типових персонажів із assets при першому запуску (лише ті,
  /// файлів яких ще немає на диску — щоб не затирати правки користувача).
  Future<void> ensureDefaults() async {
    final dir = await _charactersDir();
    for (final id in _defaultIds) {
      final file = _fileFor(dir, id);
      if (await file.exists()) continue;
      final raw = await rootBundle.loadString('assets/characters/$id.json');
      await file.writeAsString(raw, flush: true);
    }
  }

  Future<List<Character>> listAll() async {
    final dir = await _charactersDir();
    final entries = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final result = <Character>[];
    for (final file in entries) {
      try {
        final raw = await file.readAsString();
        result.add(Character.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } catch (_) {
        // Пошкоджений файл персонажа — пропускаємо, а не валимо весь список.
      }
    }
    result.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
    return result;
  }

  Future<Character?> read(String id) async {
    final dir = await _charactersDir();
    final file = _fileFor(dir, id);
    if (!await file.exists()) return null;
    final raw = await file.readAsString();
    return Character.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(Character character) async {
    final dir = await _charactersDir();
    final file = _fileFor(dir, character.id);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(character.toJson()), flush: true);
  }

  Future<void> delete(String id) async {
    final dir = await _charactersDir();
    final file = _fileFor(dir, id);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<bool> exists(String id) async {
    final dir = await _charactersDir();
    return _fileFor(dir, id).exists();
  }

  /// Безпечний ідентифікатор із назви — латиниця/цифри/дефіс/підкреслення,
  /// з перевіркою унікальності (додає -2, -3, ... за потреби).
  Future<String> uniqueIdFromName(String name) async {
    final base = _slugify(name);
    var candidate = base.isEmpty ? 'personazh' : base;
    var n = 2;
    while (await exists(candidate)) {
      candidate = '$base-$n';
      n++;
    }
    return candidate;
  }

  String _slugify(String name) {
    const translit = {
      'а': 'a',
      'б': 'b',
      'в': 'v',
      'г': 'h',
      'ґ': 'g',
      'д': 'd',
      'е': 'e',
      'є': 'ie',
      'ж': 'zh',
      'з': 'z',
      'и': 'y',
      'і': 'i',
      'ї': 'i',
      'й': 'i',
      'к': 'k',
      'л': 'l',
      'м': 'm',
      'н': 'n',
      'о': 'o',
      'п': 'p',
      'р': 'r',
      'с': 's',
      'т': 't',
      'у': 'u',
      'ф': 'f',
      'х': 'kh',
      'ц': 'ts',
      'ч': 'ch',
      'ш': 'sh',
      'щ': 'shch',
      'ь': '',
      'ю': 'iu',
      'я': 'ia',
      "'": '',
    };
    final lower = name.toLowerCase();
    final buf = StringBuffer();
    for (final ch in lower.split('')) {
      if (translit.containsKey(ch)) {
        buf.write(translit[ch]);
      } else if (RegExp(r'[a-z0-9]').hasMatch(ch)) {
        buf.write(ch);
      } else {
        buf.write('-');
      }
    }
    return buf
        .toString()
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }
}

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
  static const _defaultIds = [
    'domovychok',
    'vodyanyk',
    'povitrulya',
    'derevo',
    'vitroplav',
    'lord-monety',
  ];

  /// Незнищенні персонажі парку: їх можна редагувати, але НЕ видаляти —
  /// ні локально, ні через синхронізацію (сервер теж відкидає їхні
  /// «надгробки» — див. web/mobile_characters.py).
  static const protectedIds = {'domovychok', 'povitrulya', 'derevo'};

  /// Гачок синхронізації: CharacterSync виставляє його на старті, і кожне
  /// КОРИСТУВАЦЬКЕ збереження (touch: true) одразу пушить зміни на сервер.
  /// Статичний навмисно — екрани створюють власні екземпляри CharacterStore.
  static void Function()? onLocalChange;

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

  /// «Надгробки» видалених персонажів: id → таймстамп видалення. Живуть
  /// ПОРУЧ із текою персонажів (не всередині — щоб listAll їх не бачив) і
  /// синхронізуються нарівні з персонажами: так видалення на одному
  /// телефоні доїжджає до всіх, а не «воскресає» з сервера.
  Future<File> _tombstonesFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File(p.join(docs.path, 'character_tombstones.json'));
  }

  Future<Map<String, int>> tombstones() async {
    try {
      final file = await _tombstonesFile();
      if (!await file.exists()) return {};
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return {};
      return {
        for (final e in raw.entries)
          if (e.value is num) e.key.toString(): (e.value as num).toInt(),
      };
    } catch (_) {
      return {}; // зіпсований файл — гірше, що станеться: видалення не доїде
    }
  }

  Future<void> _writeTombstones(Map<String, int> tombs) async {
    final file = await _tombstonesFile();
    await file.writeAsString(jsonEncode(tombs), flush: true);
  }

  /// Скопіювати типових персонажів із assets при першому запуску (лише ті,
  /// файлів яких ще немає на диску — щоб не затирати правки користувача).
  /// Персонажів із «надгробком» не відроджуємо: їх свідомо видалили (напр.
  /// на іншому терміналі), і повернути їх може лише нове збереження.
  Future<void> ensureDefaults() async {
    final dir = await _charactersDir();
    final tombs = await tombstones();
    for (final id in _defaultIds) {
      if (tombs.containsKey(id)) continue;
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

  /// Зберегти персонажа. [touch] = true (типово) — це правка користувача:
  /// таймстамп оновлюється і зміна одразу асинхронно пушиться на сервер.
  /// [touch] = false — застосування версії З СЕРВЕРА: її таймстамп треба
  /// зберегти як є, інакше синхронізація зациклиться.
  Future<void> save(Character character, {bool touch = true}) async {
    final tombs = await tombstones();
    if (touch) {
      // Рівняємось на таймстамп, що ВЖЕ лежить на диску (а не в переданому
      // об'єкті): екран редагування збирає персонажа заново з updatedAt = 0,
      // і без цього правка могла б отримати час, менший за попередній
      // (напр. після персонажа з «майбутнім» часом із телефона з кривим
      // годинником) — і назавжди застрягти непоміченою для інших терміналів.
      // Надгробок теж враховуємо: нове збереження має перемогти видалення.
      final onDisk = (await read(character.id))?.updatedAt;
      var prev = onDisk ?? character.updatedAt;
      final tombTs = tombs[character.id];
      if (tombTs != null && tombTs > prev) prev = tombTs;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      character.updatedAt = now > prev ? now : prev + 1;
    }
    final dir = await _charactersDir();
    final file = _fileFor(dir, character.id);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert(character.toJson()), flush: true);
    // Живий персонаж і надгробок не можуть існувати разом — збереження
    // (і користувацьке, і з сервера) скасовує видалення.
    if (tombs.remove(character.id) != null) {
      await _writeTombstones(tombs);
    }
    if (touch) onLocalChange?.call();
  }

  /// Видалити персонажа. Повертає false для незнищенних ([protectedIds]).
  /// Видалення синхронізується через «надгробок»: інші термінали приберуть
  /// цього персонажа в себе, щойно отримають його з сервера.
  Future<bool> delete(String id) async {
    if (protectedIds.contains(id)) return false;
    final tombs = await tombstones();
    var prev = (await read(id))?.updatedAt ?? tombs[id] ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    tombs[id] = now > prev ? now : prev + 1;
    await _writeTombstones(tombs);
    final dir = await _charactersDir();
    final file = _fileFor(dir, id);
    if (await file.exists()) {
      await file.delete();
    }
    onLocalChange?.call();
    return true;
  }

  /// Застосувати видалення, що прийшло З СЕРВЕРА («останній запис
  /// перемагає»): локальна версія, новіша за надгробок, лишається — вона
  /// сама переможе на сервері наступним пушем.
  Future<void> applyRemoteDeletion(String id, int ts) async {
    if (protectedIds.contains(id)) return;
    final local = await read(id);
    if (local != null && local.updatedAt >= ts) return;
    final tombs = await tombstones();
    if ((tombs[id] ?? -1) >= ts) return; // це видалення вже відоме
    tombs[id] = ts;
    await _writeTombstones(tombs);
    if (local != null) {
      final dir = await _charactersDir();
      final file = _fileFor(dir, id);
      if (await file.exists()) {
        await file.delete();
      }
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

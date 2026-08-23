import 'transcript_utils.dart';

/// Нечітке зіставлення кодового слова з тим, що почув Vosk — прямий порт
/// domovyk_quest/wake/vosk_wake.py (той самий алгоритм: нормалізація,
/// відстань Левенштейна, зіставлення по n-грамах токенів), щоб мобільний
/// додаток чув кодове слово так само надійно, як консольний.

/// Схожість двох рядків 0..1 на основі відстані Левенштейна.
double _ratio(String a, String b) {
  if (a == b) return 1.0;
  if (a.isEmpty || b.isEmpty) return 0.0;
  final la = a.length;
  final lb = b.length;
  var prev = List<int>.generate(lb + 1, (j) => j);
  for (var i = 1; i <= la; i++) {
    final cur = List<int>.filled(lb + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= lb; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [
        cur[j - 1] + 1,
        prev[j] + 1,
        prev[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
    }
    prev = cur;
  }
  return 1.0 - prev[lb] / (la > lb ? la : lb);
}

bool _fuzzyHit(String text, String word, double threshold) {
  final tokens = text.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  if (tokens.isEmpty) return false;
  final wlen = word.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).length;
  final maxN = tokens.length < wlen + 1 ? tokens.length : wlen + 1;
  for (var n = 1; n <= maxN; n++) {
    for (var i = 0; i <= tokens.length - n; i++) {
      final span = tokens.sublist(i, i + n);
      for (final candidate in {span.join(' '), span.join('')}) {
        if (_ratio(candidate, word) >= threshold) return true;
      }
    }
  }
  return false;
}

/// Чи звучить у [heard] (текст від Vosk, фінальний або частковий) одне з
/// [wakeWords]. Точний збіг підрядка АБО нечіткий (Левенштейн ≥ [threshold]),
/// щоб компенсувати те, що Vosk часто спотворює власні назви.
bool matchesWakeWord(
  String heard,
  List<String> wakeWords, {
  double threshold = 0.70,
  bool fuzzy = true,
}) {
  final t = normalizeText(heard).trim();
  if (t.isEmpty) return false;
  for (final raw in wakeWords) {
    final w = normalizeText(raw).trim();
    if (w.isEmpty) continue;
    if (t.contains(w)) return true;
    if (fuzzy && _fuzzyHit(t, w, threshold)) return true;
  }
  return false;
}

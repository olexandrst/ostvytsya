/// Один рядок транскрипту/діагностики квесту — з часом появи: для розбору
/// проблем «коли саме» важить не менше, ніж «що саме».
class TranscriptLine {
  final String who; // 'user' | 'agent' | 'system'
  final String text;
  final DateTime at;

  TranscriptLine(this.who, this.text, {DateTime? at})
    : at = at ?? DateTime.now();

  /// «17:38:12» — той самий формат на екрані й у журналі.
  String get timeLabel {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }

  String get whoLabel {
    if (who == 'user') return 'гравець';
    if (who == 'agent') return 'персонаж';
    return 'система';
  }

  /// Рядок текстового журналу: «[17:38:12] персонаж: …».
  String get logLine => '[$timeLabel] $whoLabel: $text';
}

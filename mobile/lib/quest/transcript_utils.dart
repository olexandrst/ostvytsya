/// Порт domovyk_quest/session.py::_normalize — усе в нижній регістр, лише
/// букви/цифри/пробіли (решта → пробіл), щоб рівняти слово незалежно від
/// пунктуації й регістру. (Без NFKC-нормалізації Python-версії: для живого
/// українського мовлення ASR-моделей ці випадки на практиці не трапляються.)
final RegExp _nonWordRe = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);

String normalizeText(String text) {
  return text.toLowerCase().replaceAll(_nonWordRe, ' ');
}

/// Порт domovyk_quest/session.py — «основа» таємного слова (без останньої
/// літери, якщо слово довше 4 символів), щоб зараховувати відмінки.
String winStem(String winWord) {
  final normalized = normalizeText(winWord).trim();
  return normalized.length > 4
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
}

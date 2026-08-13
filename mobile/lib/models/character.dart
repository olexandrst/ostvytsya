import '../constants.dart';

const List<String> kProviders = ['openai', 'google'];

/// Персонаж квесту. На відміну від веб-версії (де персонаж може жити
/// структурованим YAML-сценарієм: persona/style/questions/directives), тут
/// модель спрощена до одного вільного system_prompt — так само, як для
/// персонажів із власним промптом у веб-редакторі.
class Character {
  String id;
  String displayName;
  String provider; // "openai" | "google"
  String openaiVoice;
  String voice; // Gemini voice
  double speechSpeed;
  String systemPrompt;
  String winWord;
  List<String> wakeWords;

  Character({
    required this.id,
    required this.displayName,
    this.provider = 'openai',
    this.openaiVoice = kDefaultOpenAiVoice,
    this.voice = kDefaultGeminiVoice,
    this.speechSpeed = kDefaultSpeechSpeed,
    this.systemPrompt = '',
    this.winWord = kDefaultWinWord,
    List<String>? wakeWords,
  }) : wakeWords = wakeWords ?? const [];

  factory Character.fromJson(Map<String, dynamic> json) {
    final provider = (json['provider'] as String?) ?? 'openai';
    final wakeWordsRaw = json['wake_words'];
    return Character(
      id: json['id'] as String,
      displayName: (json['display_name'] as String?) ?? '',
      provider: kProviders.contains(provider) ? provider : 'openai',
      openaiVoice: (json['openai_voice'] as String?) ?? kDefaultOpenAiVoice,
      voice: (json['voice'] as String?) ?? kDefaultGeminiVoice,
      speechSpeed:
          (json['speech_speed'] as num?)?.toDouble() ?? kDefaultSpeechSpeed,
      systemPrompt: (json['system_prompt'] as String?) ?? '',
      winWord: (json['win_word'] as String?) ?? kDefaultWinWord,
      wakeWords: wakeWordsRaw is List
          ? wakeWordsRaw
                .map((e) => e.toString())
                .where((e) => e.trim().isNotEmpty)
                .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'display_name': displayName,
    'provider': provider,
    'openai_voice': openaiVoice,
    'voice': voice,
    'speech_speed': speechSpeed,
    'system_prompt': systemPrompt,
    'win_word': winWord,
    'wake_words': wakeWords,
  };

  Character copyWith({
    String? id,
    String? displayName,
    String? provider,
    String? openaiVoice,
    String? voice,
    double? speechSpeed,
    String? systemPrompt,
    String? winWord,
    List<String>? wakeWords,
  }) {
    return Character(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      provider: provider ?? this.provider,
      openaiVoice: openaiVoice ?? this.openaiVoice,
      voice: voice ?? this.voice,
      speechSpeed: speechSpeed ?? this.speechSpeed,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      winWord: winWord ?? this.winWord,
      wakeWords: wakeWords ?? List<String>.from(this.wakeWords),
    );
  }

  /// Повний текст, що йде моделі як системна інструкція: мовні й акторські
  /// правила + власний промпт персонажа (портовано з
  /// domovyk_quest/prompt.py::build_system_instruction, гілка для персонажа
  /// з вільним system_prompt).
  String get renderedSystemInstruction {
    final speedInstruction = _speedInstruction;
    final prompt = speedInstruction == null
        ? systemPrompt.trim()
        : '${systemPrompt.trim()}\n\n$speedInstruction';
    return '$kLanguageRules\n$kPerformanceRules\n$prompt';
  }

  /// Gemini Live API, на відміну від OpenAI Realtime, не має параметра
  /// швидкості голосу в session-конфігу (лише вибір голосу) — тож для неї
  /// швидкість доводиться просити текстовою інструкцією. Для OpenAI
  /// [speechSpeed] застосовується нативно через `audio.output.speed`
  /// (openai_transport.dart), тож тут вона не потрібна.
  String? get _speedInstruction {
    if (provider != 'google') return null;
    if (speechSpeed <= 0.7) {
      return 'Говори помітно повільніше й чіткіше, ніж зазвичай, роблячи '
          'паузи між реченнями.';
    }
    if (speechSpeed <= 0.9) {
      return 'Говори трохи повільніше, ніж зазвичай.';
    }
    if (speechSpeed >= 1.3) {
      return 'Говори помітно швидше й енергійніше, ніж зазвичай.';
    }
    if (speechSpeed >= 1.1) {
      return 'Говори трохи швидше, ніж зазвичай.';
    }
    return null;
  }

  /// Кодове слово(а) активації — якщо персонаж ще не має жодного, підстава
  /// розумний типовий варіант (так само, як web/character_forms.py).
  List<String> get effectiveWakeWords => wakeWords.isNotEmpty
      ? wakeWords
      : [displayName.isNotEmpty ? displayName : 'Оствиця'];
}

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

  /// Слова від ГОСТЕЙ, що завершують сесію (напр. «Каліпсо» для екскурсії):
  /// почувши одне з них у мовленні гравців, застосунок дає персонажу
  /// попрощатись і закриває сесію. Порожньо — сесія закінчується лише словом
  /// перемоги персонажа чи тайм-аутом.
  List<String> stopWords;

  /// Прокидатись від БУДЬ-ЯКОГО голосу, а не лише від кодового слова
  /// (персонаж-зазивайло біля входу: чує людей — і озивається).
  bool wakeOnVoice;

  /// Скільки секунд тиші завершують сесію; null — типова константа
  /// застосунку (kInactivityTimeoutS). Зазивайлу потрібна коротка (~60 с),
  /// квесту з фізичним пошуком — довга.
  int? inactivityTimeoutS;

  /// Екскурсовод: якщо гості мовчать стільки секунд після репліки персонажа,
  /// застосунок просить його продовжити розповідь наступною частиною — бо
  /// модель сама по себе говорить лише у відповідь. null — вимкнено.
  int? autoContinueS;

  /// Unix-час (секунди) останньої правки користувачем — основа синхронізації
  /// між терміналами («останній запис перемагає»). 0 — типовий персонаж із
  /// комплекту, якого ще ніхто не редагував: будь-яка правка на будь-якому
  /// телефоні його переважить.
  int updatedAt;

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
    List<String>? stopWords,
    this.wakeOnVoice = false,
    this.inactivityTimeoutS,
    this.autoContinueS,
    this.updatedAt = 0,
  }) : wakeWords = wakeWords ?? const [],
       stopWords = stopWords ?? const [];

  static int? _positiveInt(Object? raw) {
    final n = (raw as num?)?.toInt();
    return (n != null && n > 0) ? n : null;
  }

  static List<String> _words(Object? raw) => raw is List
      ? raw
            .map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty)
            .toList()
      : const [];

  factory Character.fromJson(Map<String, dynamic> json) {
    final provider = (json['provider'] as String?) ?? 'openai';
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
      wakeWords: _words(json['wake_words']),
      stopWords: _words(json['stop_words']),
      wakeOnVoice: json['wake_on_voice'] == true,
      inactivityTimeoutS: _positiveInt(json['inactivity_timeout_s']),
      autoContinueS: _positiveInt(json['auto_continue_s']),
      updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
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
    'stop_words': stopWords,
    'wake_on_voice': wakeOnVoice,
    'inactivity_timeout_s': inactivityTimeoutS,
    'auto_continue_s': autoContinueS,
    'updated_at': updatedAt,
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
    List<String>? stopWords,
    bool? wakeOnVoice,
    int? inactivityTimeoutS,
    int? autoContinueS,
    int? updatedAt,
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
      stopWords: stopWords ?? List<String>.from(this.stopWords),
      wakeOnVoice: wakeOnVoice ?? this.wakeOnVoice,
      inactivityTimeoutS: inactivityTimeoutS ?? this.inactivityTimeoutS,
      autoContinueS: autoContinueS ?? this.autoContinueS,
      updatedAt: updatedAt ?? this.updatedAt,
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

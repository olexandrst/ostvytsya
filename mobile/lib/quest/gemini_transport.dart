import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../constants.dart';
import '../models/character.dart';
import 'transport.dart';

/// Пряме WebSocket-з'єднання з Gemini Live API (BidiGenerateContent) — без
/// офіційного Dart SDK, тож протокол реалізовано вручну на основі вихідного
/// коду google-genai (Python) як єдиного доступного авторитетного джерела.
///
/// Ключова асиметрія протоколу (підтверджено читанням _live_converters.py):
///   • клієнт → сервер: верхній рівень конверта — snake_case
///     (`setup`, `client_content`, `realtime_input`), вкладені поля — camelCase;
///   • сервер → клієнт: усе camelCase (`serverContent`, `modelTurn`, ...).
///
/// Аудіо: вхід 16 кГц PCM16 моно, вихід 24 кГц PCM16 моно — base64 у JSON,
/// НЕ бінарні кадри.
class GeminiTransport implements QuestTransport {
  final Character character;
  final String apiKey;

  WebSocketChannel? _channel;
  final _eventsController = StreamController<QuestTransportEvent>.broadcast();
  final _audioController = StreamController<Uint8List>.broadcast();
  StreamSubscription? _sub;
  bool _setupComplete = false;
  int _turnAudioBytes = 0;
  int _consecutiveSilentTurns = 0;

  static const _maxRecoveryAttempts = 4;

  // Gemini 3.1 інколи повертає технічно "непорожній" inlineData-шматок у
  // лічені байти (підтверджено на реальному пристрої — рівно 2 байти,
  // тобто один PCM16-семпл) замість реальної озвучки репліки. Якщо рахувати
  // БУДЬ-ЯКИЙ непорожній шматок за "хід озвучено", механізм відновлення
  // нижче зупиняється на цій "заглушці", а дитина фактично нічого не чує.
  // Тому за успіх рахуємо лише хід, де сумарно прийшло не менше стількох
  // байт — це вже не разовий артефакт, а справжня коротка фраза.
  static const _minMeaningfulAudioBytes = 4800; // ~100мс на 24 кГц PCM16

  GeminiTransport(this.character, this.apiKey);

  @override
  Stream<QuestTransportEvent> get events => _eventsController.stream;

  @override
  Stream<Uint8List> get outputAudio => _audioController.stream;

  @override
  int get inputSampleRate => 16000;

  @override
  int get outputSampleRate => 24000;

  @override
  Future<void> connect() async {
    final uri = Uri.parse(
      'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent',
    );
    _channel = IOWebSocketChannel.connect(
      uri,
      headers: {'x-goog-api-key': apiKey},
    );
    await _channel!.ready;
    _sub = _channel!.stream.listen(
      _onMessage,
      onError: (Object err) {
        _eventsController.add(
          QuestTransportEvent(QuestEventKind.error, text: 'Gemini: $err'),
        );
      },
      onDone: () {
        _eventsController.add(const QuestTransportEvent(QuestEventKind.closed));
      },
      cancelOnError: false,
    );

    _send({'setup': _setupMessage()});
  }

  Map<String, dynamic> _setupMessage() {
    var voice = character.voice.trim();
    if (!kGeminiVoiceLabels.containsKey(voice)) voice = kDefaultGeminiVoice;

    return {
      'model': 'models/$kGeminiLiveModel',
      'generationConfig': {
        'responseModalities': ['AUDIO'],
        'speechConfig': {
          'voiceConfig': {
            'prebuiltVoiceConfig': {'voiceName': voice},
          },
        },
      },
      'systemInstruction': {
        'parts': [
          {'text': character.renderedSystemInstruction},
        ],
      },
      'inputAudioTranscription': {},
      'outputAudioTranscription': {},
      'contextWindowCompression': {'slidingWindow': {}},
    };
  }

  void _sendGreeting() {
    if (kGeminiLiveModel.contains('3.1')) {
      // Для gemini-3.1-flash-live-preview client_content офіційно
      // підтримується лише для "засівання" початкового контексту й НЕ
      // генерує голосової відповіді (задокументована зміна порівняно з
      // 2.5 — підтверджено на реальному пристрої: текст привітання
      // приходив повністю, а аудіо — 2 байти за весь хід). Тому для 3.1
      // шлемо привітання як realtime_input.text — той самий канал, яким
      // іде живий голос гравця і який надійно генерує аудіо-відповідь.
      // Перед цим ще й "будимо" аудіо-канал коротким шматком тиші —
      // достеменно той самий шлях, яким генерується голос під час
      // звичайного ходу з мікрофону. Якщо цей хід теж пройде без аудіо —
      // про це подбає загальний механізм відновлення в _onTurnComplete().
      _sendSilentAudioPrimer();
      _send({
        'realtime_input': {'text': kGreetingTrigger},
      });
      return;
    }
    _send({
      'client_content': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': kGreetingTrigger},
            ],
          },
        ],
        'turnComplete': true,
      },
    });
  }

  /// Коротка "тиша" через realtime_input.audio — той самий канал, яким іде
  /// живий голос гравця і який стабільно генерує аудіо-відповідь. Ціль —
  /// активувати аудіо-шлях моделі ще до текстового привітання (обхід
  /// холодного старту gemini-3.1-flash-live-preview).
  void _sendSilentAudioPrimer() {
    const durationMs = 400;
    final sampleCount = (inputSampleRate * durationMs / 1000).round();
    sendAudio(Uint8List(sampleCount * 2)); // PCM16 нулі = тиша
  }

  /// Відомий, визнаний самим Google баг якості gemini-3.1-flash-live-preview
  /// (google-gemini/cookbook issue #1197): БУДЬ-ЯКИЙ хід (не лише перше
  /// привітання — підтверджено на реальному пристрої й для звичайних ходів
  /// посеред квесту) інколи взагалі не озвучується (або озвучується
  /// мізерною "заглушкою" в кілька байт — теж підтверджено наживо), хоча
  /// текст приходить повністю. Викликається на кожен turnComplete: якщо за
  /// весь хід не прийшло досить аудіо ([_minMeaningfulAudioBytes]) —
  /// просимо модель озвучити ту саму репліку ще раз (до
  /// [_maxRecoveryAttempts] спроб поспіль, далі здаємось, щоб не
  /// зациклитись, якщо модель геть не хоче говорити).
  void _onTurnComplete() {
    if (_turnAudioBytes >= _minMeaningfulAudioBytes) {
      _consecutiveSilentTurns = 0;
    } else if (kGeminiLiveModel.contains('3.1') &&
        _consecutiveSilentTurns < _maxRecoveryAttempts) {
      _consecutiveSilentTurns++;
      _sendSilentAudioPrimer();
      _send({
        'realtime_input': {
          'text':
              '[Службовий сигнал — не читай його вголос і не пиши новий '
              'текст. Просто озвуч вголос СВОЄЮ останньою реплікою — '
              'гравець тебе не почув.]',
        },
      });
    } else {
      _consecutiveSilentTurns = 0;
    }
    _turnAudioBytes = 0;
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      final text = raw is String ? raw : utf8.decode(raw as List<int>);
      msg = jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      return;
    }

    if (msg.containsKey('setupComplete')) {
      if (!_setupComplete) {
        _setupComplete = true;
        _eventsController.add(const QuestTransportEvent(QuestEventKind.ready));
        _sendGreeting();
      }
      return;
    }

    final serverContent = msg['serverContent'];
    if (serverContent is Map) {
      _handleServerContent(serverContent);
    }

    if (msg.containsKey('goAway')) {
      _eventsController.add(const QuestTransportEvent(QuestEventKind.closed));
    }
  }

  void _handleServerContent(Map serverContent) {
    final modelTurn = serverContent['modelTurn'];
    if (modelTurn is Map) {
      final parts = modelTurn['parts'];
      if (parts is List) {
        for (final part in parts) {
          if (part is Map) {
            final inline = part['inlineData'];
            if (inline is Map) {
              final data = inline['data'];
              if (data is String && data.isNotEmpty) {
                final decoded = base64Decode(data);
                _turnAudioBytes += decoded.length;
                _audioController.add(decoded);
              }
            }
          }
        }
      }
    }

    final inputTranscription = serverContent['inputTranscription'];
    if (inputTranscription is Map) {
      final t = inputTranscription['text'];
      if (t is String && t.isNotEmpty) {
        _eventsController.add(
          QuestTransportEvent(QuestEventKind.userTranscriptDelta, text: t),
        );
      }
    }

    final outputTranscription = serverContent['outputTranscription'];
    if (outputTranscription is Map) {
      final t = outputTranscription['text'];
      if (t is String && t.isNotEmpty) {
        _eventsController.add(
          QuestTransportEvent(QuestEventKind.agentTranscriptDelta, text: t),
        );
      }
    }

    if (serverContent['interrupted'] == true) {
      _eventsController.add(
        const QuestTransportEvent(QuestEventKind.interrupted),
      );
    }

    if (serverContent['turnComplete'] == true) {
      _eventsController.add(
        const QuestTransportEvent(QuestEventKind.turnComplete),
      );
      _onTurnComplete();
    }
  }

  void _send(Map<String, dynamic> payload) {
    _channel?.sink.add(jsonEncode(payload));
  }

  @override
  void sendAudio(Uint8List pcm16) {
    if (!_setupComplete) return;
    _send({
      'realtime_input': {
        'audio': {
          'data': base64Encode(pcm16),
          'mimeType': 'audio/pcm;rate=16000',
        },
      },
    });
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await _channel?.sink.close();
    await _eventsController.close();
    await _audioController.close();
  }
}

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
  bool _receivedAnyAudio = false;
  bool _sentRecoveryCue = false;
  Timer? _recoveryTimer;

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
      _send({
        'realtime_input': {'text': kGreetingTrigger},
      });
      _scheduleRecoveryCueIfSilent();
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

  /// Відомий, визнаний самим Google баг якості gemini-3.1-flash-live-preview
  /// (google-gemini/cookbook issue #1197): перший хід інколи взагалі не
  /// озвучується (холодний старт/самоперебивання). Спільнота повідомляє про
  /// робочий обхід — надіслати ще один короткий сигнал через
  /// realtime_input.text, якщо за пару секунд аудіо так і не з'явилось.
  /// Лише ОДНА спроба відновлення за весь квест.
  void _scheduleRecoveryCueIfSilent() {
    _recoveryTimer?.cancel();
    _recoveryTimer = Timer(const Duration(milliseconds: 2500), () {
      if (_sentRecoveryCue || _receivedAnyAudio || _channel == null) return;
      _sentRecoveryCue = true;
      _send({
        'realtime_input': {
          'text':
              '[Службовий сигнал — не читай його вголос і не пиши новий '
              'текст. Просто озвуч вголос СВОЄЮ реплікою те, що ти щойно '
              'сказав — гравець тебе поки що не почув.]',
        },
      });
    });
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
                _receivedAnyAudio = true;
                _audioController.add(base64Decode(data));
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
    _recoveryTimer?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    await _eventsController.close();
    await _audioController.close();
  }
}

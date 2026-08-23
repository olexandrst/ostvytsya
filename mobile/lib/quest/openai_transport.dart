import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../constants.dart';
import '../models/character.dart';
import 'transport.dart';

/// Пряме WebSocket-з'єднання з OpenAI Realtime API (без ephemeral-токена й
/// без сервера-посередника — телефон сам тримає ключ користувача).
///
/// Формат аудіо: PCM16, 24 кГц, моно, little-endian — для входу й виходу.
/// Аудіо йде як JSON-події з base64 (не бінарні кадри).
class OpenAiTransport implements QuestTransport {
  final Character character;
  final String apiKey;

  WebSocketChannel? _channel;
  final _eventsController = StreamController<QuestTransportEvent>.broadcast();
  final _audioController = StreamController<Uint8List>.broadcast();
  StreamSubscription? _sub;
  bool _sessionReady = false;

  OpenAiTransport(this.character, this.apiKey);

  @override
  Stream<QuestTransportEvent> get events => _eventsController.stream;

  @override
  Stream<Uint8List> get outputAudio => _audioController.stream;

  @override
  int get inputSampleRate => 24000;

  @override
  int get outputSampleRate => 24000;

  @override
  Future<void> connect() async {
    final uri = Uri.parse(
      'wss://api.openai.com/v1/realtime?model=$kOpenAiRealtimeModel',
    );
    _channel = IOWebSocketChannel.connect(
      uri,
      headers: {
        'Authorization': 'Bearer $apiKey',
        'OpenAI-Beta': 'realtime=v1',
      },
    );
    await _channel!.ready;
    _sub = _channel!.stream.listen(
      _onMessage,
      onError: (Object err) {
        _eventsController.add(
          QuestTransportEvent(QuestEventKind.error, text: 'OpenAI: $err'),
        );
      },
      onDone: () {
        _eventsController.add(const QuestTransportEvent(QuestEventKind.closed));
      },
      cancelOnError: false,
    );

    _send({'type': 'session.update', 'session': _sessionConfig()});
  }

  Map<String, dynamic> _sessionConfig() {
    var voice = character.openaiVoice.trim();
    if (!kOpenAiVoices.contains(voice)) voice = kDefaultOpenAiVoice;
    var speed = character.speechSpeed;
    if (speed < 0.25) speed = 0.25;
    if (speed > 2.0) speed = 2.0;

    return {
      'type': 'realtime',
      'model': kOpenAiRealtimeModel,
      'instructions': character.renderedSystemInstruction,
      'audio': {
        'input': {
          'transcription': {'model': 'gpt-realtime-whisper', 'language': 'uk'},
          'turn_detection': {
            'type': 'server_vad',
            'interrupt_response': false,
            'create_response': true,
            'silence_duration_ms': 700,
          },
        },
        'output': {'voice': voice, 'speed': speed},
      },
    };
  }

  void _sendGreeting() {
    _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': kGreetingTrigger},
        ],
      },
    });
    _send({'type': 'response.create'});
  }

  void _onMessage(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = msg['type'] as String?;
    switch (type) {
      case 'session.updated':
        if (!_sessionReady) {
          _sessionReady = true;
          _eventsController.add(
            const QuestTransportEvent(QuestEventKind.ready),
          );
          _sendGreeting();
        }
        break;
      case 'response.output_audio.delta':
        final b64 = msg['delta'] as String?;
        if (b64 != null && b64.isNotEmpty) {
          _audioController.add(base64Decode(b64));
        }
        break;
      case 'response.output_audio_transcript.delta':
        final delta = msg['delta'] as String?;
        if (delta != null && delta.isNotEmpty) {
          _eventsController.add(
            QuestTransportEvent(
              QuestEventKind.agentTranscriptDelta,
              text: delta,
            ),
          );
        }
        break;
      case 'conversation.item.input_audio_transcription.delta':
        final delta = msg['delta'] as String?;
        if (delta != null && delta.isNotEmpty) {
          _eventsController.add(
            QuestTransportEvent(
              QuestEventKind.userTranscriptDelta,
              text: delta,
            ),
          );
        }
        break;
      case 'response.done':
        _eventsController.add(
          const QuestTransportEvent(QuestEventKind.turnComplete),
        );
        break;
      case 'error':
        final err = msg['error'];
        final message = err is Map
            ? (err['message']?.toString() ?? 'помилка')
            : 'помилка';
        _eventsController.add(
          QuestTransportEvent(QuestEventKind.error, text: message),
        );
        break;
      default:
        break;
    }
  }

  void _send(Map<String, dynamic> payload) {
    _channel?.sink.add(jsonEncode(payload));
  }

  @override
  void sendAudio(Uint8List pcm16) {
    if (!_sessionReady) return;
    _send({'type': 'input_audio_buffer.append', 'audio': base64Encode(pcm16)});
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await _channel?.sink.close();
    await _eventsController.close();
    await _audioController.close();
  }
}

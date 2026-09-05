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
///
/// ВІДНОВЛЕННЯ СЕСІЇ. Одне WebSocket-з'єднання Live API живе ~10 хвилин:
/// перед розривом сервер шле `goAway`, а сама сесія (контекст розмови)
/// може жити далі, якщо перепід'єднатися з handle із `sessionResumptionUpdate`
/// (підтверджено наживо: квест обривався рівно на 9-й хвилині одразу після
/// репліки персонажа). Тому транспорт запам'ятовує останній resumable handle
/// і на `goAway` чи раптовий обрив (перемикання wifi/4g у парку) сам
/// відкриває нове з'єднання з цим handle — персонаж продовжує з того самого
/// місця, без повторного привітання. Контролер квесту про це дізнається лише
/// інформаційним рядком.
class GeminiTransport implements QuestTransport {
  final Character character;
  final String apiKey;

  static final _uri = Uri.parse(
    'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent',
  );

  WebSocketChannel? _channel;
  final _eventsController = StreamController<QuestTransportEvent>.broadcast();
  final _audioController = StreamController<Uint8List>.broadcast();
  StreamSubscription? _sub;
  bool _setupComplete = false;
  int _turnAudioBytes = 0;
  int _turnTextChars = 0;
  int _consecutiveSilentTurns = 0;

  // ── Стан відновлення сесії ────────────────────────────────────────────
  /// Останній handle, з яким сервер дозволяє відновити сесію.
  String? _resumeHandle;

  /// `ready` і привітання шлемо лише ОДИН раз за квест — на відновленому
  /// з'єднанні розмова просто триває.
  bool _everReady = false;
  bool _closedByUs = false;
  bool _reconnecting = false;

  /// Завершується, коли поточне з'єднання отримало `setupComplete`
  /// (true) або померло раніше (false).
  Completer<bool>? _setupDone;

  /// Мікрофон під час переп'єднання: кілька секунд не губимо, а
  /// дошлемо, щойно нове з'єднання буде готове.
  final _pendingAudio = <Uint8List>[];
  int _pendingAudioBytes = 0;
  static const _maxPendingAudioBytes = 16000 * 2 * 3; // ~3 с PCM16 16 кГц

  static const _reconnectAttempts = 5;
  static const _connectTimeout = Duration(seconds: 10);
  static const _setupTimeout = Duration(seconds: 15);

  static const _maxRecoveryAttempts = 4;

  // Gemini 3.1 інколи повертає технічно "непорожній" inlineData-шматок у
  // лічені байти (підтверджено на реальному пристрої — рівно 2 байти,
  // тобто один PCM16-семпл) замість реальної озвучки репліки, а інколи
  // озвучує лише ХВІСТ довгої репліки, обірвавши вступ (теж підтверджено
  // наживо: 600+ символів тексту, але лише ~190мс аудіо — фізично
  // неможливо для реальної озвучки такого обсягу). Тому "хід озвучено"
  // рахуємо не за фіксованим мінімумом байт, а відносно ДОВЖИНИ тексту
  // цього ходу: скільки б часу пішло на озвучку в дуже швидкому темпі
  // (нижня межа, щоб не ганяти повторні спроби для просто швидкої мови) —
  // і вимагаємо хоча б частку від цього часу.
  static const _fastCharsPerSecond = 20; // дуже швидкий темп мовлення
  static const _minVoicedFraction = 0.3; // ≥30% від "швидкої" тривалості
  static const _minMeaningfulAudioBytes = 4800; // підлога для короткого тексту, ~100мс

  GeminiTransport(this.character, this.apiKey);

  @override
  Stream<QuestTransportEvent> get events => _eventsController.stream;

  @override
  Stream<Uint8List> get outputAudio => _audioController.stream;

  @override
  int get inputSampleRate => 16000;

  @override
  int get outputSampleRate => 24000;

  void _emit(QuestTransportEvent event) {
    // Після close() контролер уже нічого не слухає, а add() у закритий
    // StreamController кидає виняток — пізні події просто відкидаємо.
    if (!_eventsController.isClosed) _eventsController.add(event);
  }

  @override
  Future<void> connect() async {
    await _open();
  }

  /// Відкрити з'єднання й надіслати setup. З [resumeHandle] сервер
  /// відновлює попередню сесію замість нової.
  Future<void> _open({String? resumeHandle}) async {
    final channel = IOWebSocketChannel.connect(
      _uri,
      headers: {'x-goog-api-key': apiKey},
      connectTimeout: _connectTimeout,
    );
    await channel.ready;
    if (_closedByUs) {
      unawaited(_discard(channel, null));
      return;
    }
    _channel = channel;
    _setupComplete = false;
    final setupDone = Completer<bool>();
    _setupDone = setupDone;
    _sub = channel.stream.listen(
      _onMessage,
      onError: (Object err) {
        if (!identical(channel, _channel)) return; // уже замінене з'єднання
        _onConnectionLost(channel, error: err);
      },
      onDone: () {
        if (!identical(channel, _channel) || _closedByUs) return;
        _onConnectionLost(channel);
      },
      cancelOnError: false,
    );

    _send({'setup': _setupMessage(resumeHandle: resumeHandle)});
  }

  /// Тихо прибрати з'єднання, яке нам більше не потрібне.
  Future<void> _discard(
    WebSocketChannel? channel,
    StreamSubscription? sub,
  ) async {
    try {
      await sub?.cancel();
    } catch (_) {}
    try {
      await channel?.sink.close();
    } catch (_) {}
  }

  /// Поточне з'єднання померло не з нашої волі. Якщо є handle — відновлюємо
  /// сесію; якщо немає (сервер відкинув setup, напр. через недійсний ключ,
  /// або впав ще до першого `sessionResumptionUpdate`) — повідомляємо
  /// контролеру код і причину закриття, як і раніше.
  void _onConnectionLost(WebSocketChannel channel, {Object? error}) {
    final code = channel.closeCode;
    final reason = channel.closeReason?.trim() ?? '';
    final parts = <String>[
      if (error != null) '$error',
      if (code != null || reason.isNotEmpty)
        'код ${code ?? "?"}${reason.isEmpty ? "" : ": $reason"}',
    ];
    final detail = parts.isEmpty ? null : parts.join('; ');

    final setupDone = _setupDone;
    if (setupDone != null && !setupDone.isCompleted) setupDone.complete(false);

    if (_reconnecting) return; // цикл відновлення сам розбереться
    if (_resumeHandle == null) {
      _emit(QuestTransportEvent(QuestEventKind.closed, text: detail));
      return;
    }
    unawaited(
      _reconnect(
        "з'єднання обірвалось${detail == null ? '' : ' ($detail)'}",
      ),
    );
  }

  /// Перепід'єднатися з останнім handle. Кілька спроб із наростаючою
  /// паузою — мережа в парку може зникати на секунди при перемиканні
  /// wifi/4g. Якщо не вдалося зовсім — лише тоді квест завершується.
  Future<void> _reconnect(String why) async {
    if (_reconnecting || _closedByUs) return;
    _reconnecting = true;
    // Старе з'єднання від'єднуємо одразу: його onDone/onError більше не
    // наша справа (гарантує перевірка identical() у слухачах).
    final old = _channel;
    final oldSub = _sub;
    _channel = null;
    _sub = null;
    _setupComplete = false;
    unawaited(_discard(old, oldSub));

    try {
      for (var attempt = 1; attempt <= _reconnectAttempts; attempt++) {
        if (_closedByUs) return;
        try {
          await _open(resumeHandle: _resumeHandle);
          if (_closedByUs) return; // квест зупинили, поки ми під'єднувались
          final done = _setupDone;
          final ok = done != null && await done.future.timeout(_setupTimeout);
          if (!ok) throw StateError('setup не завершився');
          _emit(
            QuestTransportEvent(
              QuestEventKind.info,
              text:
                  "З'єднання з Gemini відновлено ($why; спроба $attempt) — "
                  'розмова триває з того ж місця.',
            ),
          );
          return;
        } catch (_) {
          final c = _channel;
          final s = _sub;
          _channel = null;
          _sub = null;
          _setupComplete = false;
          unawaited(_discard(c, s));
          if (attempt < _reconnectAttempts) {
            await Future<void>.delayed(Duration(seconds: attempt));
          }
        }
      }
      _emit(
        QuestTransportEvent(
          QuestEventKind.closed,
          text:
              "не вдалося відновити з'єднання після $_reconnectAttempts "
              'спроб ($why)',
        ),
      );
    } finally {
      _reconnecting = false;
    }
  }

  Map<String, dynamic> _setupMessage({String? resumeHandle}) {
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
      // Просимо сервер видавати handle для відновлення; з handle —
      // відновлюємо попередню сесію замість нової.
      'sessionResumption': resumeHandle == null ? {} : {'handle': resumeHandle},
    };
  }

  void _sendGreeting() => sendText(kGreetingTrigger);

  @override
  void sendText(String text) {
    if (!_setupComplete) return;
    if (kGeminiLiveModel.contains('3.1')) {
      // Для gemini-3.1-flash-live-preview client_content офіційно
      // підтримується лише для "засівання" початкового контексту й НЕ
      // генерує голосової відповіді (задокументована зміна порівняно з
      // 2.5 — підтверджено на реальному пристрої: текст привітання
      // приходив повністю, а аудіо — 2 байти за весь хід). Тому для 3.1
      // шлемо текст як realtime_input.text — той самий канал, яким іде
      // живий голос гравця і який надійно генерує аудіо-відповідь.
      // Перед цим ще й "будимо" аудіо-канал коротким шматком тиші —
      // достеменно той самий шлях, яким генерується голос під час
      // звичайного ходу з мікрофону. Якщо цей хід теж пройде без аудіо —
      // про це подбає загальний механізм відновлення в _onTurnComplete().
      _sendSilentAudioPrimer();
      _send({
        'realtime_input': {'text': text},
      });
      return;
    }
    _send({
      'client_content': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text},
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
  /// посеред квесту) інколи взагалі не озвучується, або озвучується лише
  /// частково (хвіст репліки без вступу — теж підтверджено наживо), хоча
  /// текст приходить повністю. Викликається на кожен turnComplete: якщо
  /// озвученого аудіо явно замало відносно довжини тексту цього ходу —
  /// просимо модель озвучити ту саму репліку ще раз (до
  /// [_maxRecoveryAttempts] спроб поспіль, далі здаємось, щоб не
  /// зациклитись, якщо модель геть не хоче говорити).
  void _onTurnComplete() {
    final expectedBytes =
        (_turnTextChars / _fastCharsPerSecond) * outputSampleRate * 2;
    final requiredBytes = (expectedBytes * _minVoicedFraction).clamp(
      _minMeaningfulAudioBytes,
      double.infinity,
    );
    if (_turnAudioBytes >= requiredBytes) {
      _consecutiveSilentTurns = 0;
    } else if (kGeminiLiveModel.contains('3.1') &&
        _consecutiveSilentTurns < _maxRecoveryAttempts) {
      _consecutiveSilentTurns++;
      _sendSilentAudioPrimer();
      _send({
        'realtime_input': {
          'text':
              '[Службовий сигнал — не читай його вголос і не пиши новий '
              'текст. Просто озвуч вголос ПОВНІСТЮ СВОЄЮ останньою '
              'реплікою від самого початку — гравець тебе не почув.]',
        },
      });
    } else {
      _consecutiveSilentTurns = 0;
    }
    _turnAudioBytes = 0;
    _turnTextChars = 0;
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
        final done = _setupDone;
        if (done != null && !done.isCompleted) done.complete(true);
        if (!_everReady) {
          _everReady = true;
          _emit(const QuestTransportEvent(QuestEventKind.ready));
          _sendGreeting();
        } else {
          _flushPendingAudio();
        }
      }
      return;
    }

    final resumption = msg['sessionResumptionUpdate'];
    if (resumption is Map) {
      final handle = resumption['newHandle'];
      if (resumption['resumable'] == true &&
          handle is String &&
          handle.isNotEmpty) {
        _resumeHandle = handle;
      }
    }

    final serverContent = msg['serverContent'];
    if (serverContent is Map) {
      _handleServerContent(serverContent);
    }

    if (msg.containsKey('goAway')) {
      // Сервер попереджає, що незабаром закриє ЦЕ з'єднання (ліміт ~10 хв).
      // Якщо handle уже є — перепід'єднуємось одразу, не чекаючи обриву;
      // якщо ще немає — дочекаємось onDone: раптом handle прийде до того.
      final goAway = msg['goAway'];
      final timeLeft = goAway is Map ? goAway['timeLeft'] : null;
      if (_resumeHandle != null) {
        unawaited(
          _reconnect(
            "сервер оголосив закриття з'єднання (goAway"
            "${timeLeft == null ? '' : ', лишалось $timeLeft'})",
          ),
        );
      }
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
                if (!_audioController.isClosed) _audioController.add(decoded);
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
        _emit(
          QuestTransportEvent(QuestEventKind.userTranscriptDelta, text: t),
        );
      }
    }

    final outputTranscription = serverContent['outputTranscription'];
    if (outputTranscription is Map) {
      final t = outputTranscription['text'];
      if (t is String && t.isNotEmpty) {
        _turnTextChars += t.length;
        _emit(
          QuestTransportEvent(QuestEventKind.agentTranscriptDelta, text: t),
        );
      }
    }

    if (serverContent['interrupted'] == true) {
      _emit(const QuestTransportEvent(QuestEventKind.interrupted));
    }

    if (serverContent['turnComplete'] == true) {
      _emit(const QuestTransportEvent(QuestEventKind.turnComplete));
      _onTurnComplete();
    }
  }

  void _send(Map<String, dynamic> payload) {
    _channel?.sink.add(jsonEncode(payload));
  }

  @override
  void sendAudio(Uint8List pcm16) {
    if (!_setupComplete) {
      // До першого setup мікрофон ще не ввімкнено (пайплайн стартує на
      // `ready`), тож сюди потрапляє лише голос під час переп'єднання —
      // притримуємо кілька секунд, щоб не обірвати відповідь дитини.
      if (_everReady) _bufferPendingAudio(pcm16);
      return;
    }
    _send({
      'realtime_input': {
        'audio': {
          'data': base64Encode(pcm16),
          'mimeType': 'audio/pcm;rate=16000',
        },
      },
    });
  }

  void _bufferPendingAudio(Uint8List pcm16) {
    _pendingAudio.add(pcm16);
    _pendingAudioBytes += pcm16.length;
    while (_pendingAudioBytes > _maxPendingAudioBytes && _pendingAudio.isNotEmpty) {
      _pendingAudioBytes -= _pendingAudio.removeAt(0).length;
    }
  }

  void _flushPendingAudio() {
    final chunks = List<Uint8List>.from(_pendingAudio);
    _pendingAudio.clear();
    _pendingAudioBytes = 0;
    for (final chunk in chunks) {
      sendAudio(chunk);
    }
  }

  @override
  Future<void> close() async {
    _closedByUs = true;
    await _sub?.cancel();
    try {
      await _channel?.sink.close();
    } catch (_) {}
    await _eventsController.close();
    await _audioController.close();
  }
}

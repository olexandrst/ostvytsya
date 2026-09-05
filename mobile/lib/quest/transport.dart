import 'dart:typed_data';

import '../models/character.dart';

enum QuestEventKind {
  ready,
  userTranscriptDelta,
  agentTranscriptDelta,
  turnComplete,
  interrupted,
  error,
  closed,

  /// Інформаційне повідомлення для діагностики (напр. «з'єднання
  /// відновлено») — нічого не змінює в перебігу квесту.
  info,
}

class QuestTransportEvent {
  final QuestEventKind kind;
  final String? text;

  const QuestTransportEvent(this.kind, {this.text});
}

/// Спільний інтерфейс для прямого підключення до Gemini Live чи OpenAI
/// Realtime з телефону — без сервера-посередника. Контролер квесту
/// (QuestController) працює лише через цей інтерфейс, не знаючи, який саме
/// провайдер обрано для персонажа.
abstract class QuestTransport {
  /// Усі події сесії, крім самого аудіо (воно йде окремим потоком нижче,
  /// бо частих бінарних шматків забагато, щоб змішувати їх з подіями).
  Stream<QuestTransportEvent> get events;

  /// Голос персонажа: сирий PCM16 моно, [outputSampleRate] Гц, для програвання.
  Stream<Uint8List> get outputAudio;

  /// Частота дискретизації, якої очікує провайдер для мікрофона.
  int get inputSampleRate;

  /// Частота дискретизації голосу персонажа, що надходить назад.
  int get outputSampleRate;

  /// Підключитися, надіслати налаштування сесії й службовий сигнал вітання,
  /// щоб персонаж заговорив першим.
  Future<void> connect();

  /// Надіслати шматок мікрофону (сирий PCM16 моно, inputSampleRate Гц).
  void sendAudio(Uint8List pcm16);

  /// Надіслати моделі текстову репліку від імені гравця (службові сигнали:
  /// привітання, «повтори слово»). Модель відповідає на неї голосом, як на
  /// звичайний хід. До готовності сесії — тихо ігнорується.
  void sendText(String text);

  Future<void> close();
}

typedef QuestTransportFactory =
    QuestTransport Function(Character character, String apiKey);

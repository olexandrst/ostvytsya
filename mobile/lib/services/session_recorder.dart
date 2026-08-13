import 'dart:async';
import 'dart:typed_data';

import 'native_session_encoder.dart';
import 'recordings_store.dart';

/// Автоматичний запис однієї спроби квесту (від почутого кодового слова до
/// перемоги/тайм-ауту/зупинки) в один стиснений .m4a-файл на диску — для
/// подальшого прослуховування/діагностики. Мікрофон (голос дитини) і голос
/// персонажа пишуться в той самий файл у реальному хронологічному порядку;
/// оскільки [AudioPipeline] апаратно вимикає мікрофон, поки говорить
/// персонаж (напівдуплекс), напряму накладання немає — лише паузи, які
/// заповнюються тишею за годинником, щоб темп розмови в записі був
/// правдивим. Кодування в AAC (через [NativeSessionEncoder]) — нестиснений
/// WAV на 24 кГц важив би ~86 МБ за максимальну 30-хвилинну сесію, .m4a на
/// 48 кбіт/с — ~11 МБ за той самий час.
class SessionRecorder {
  static const _targetRate = 24000; // Hz, той самий, що й вихід Gemini/OpenAI

  // Сирий сигнал мікрофону (без AGC/нормалізації) на телефоні, який дитина
  // тримає на відстані, у записі виходить у рази тихішим за синтезований
  // голос персонажа (той уже нормалізований на боці Gemini/OpenAI) —
  // технічно записаний, але на відтворенні майже не чутний. Підсилюємо
  // перед кодуванням лише мікрофонні шматки, з захистом від кліпінгу.
  static const _micGain = 4.0;

  final _encoder = NativeSessionEncoder();
  String? _path;
  int _samplesWritten = 0;
  int _micSamplesWritten = 0;
  int _agentSamplesWritten = 0;
  final _stopwatch = Stopwatch();
  bool _active = false;
  Future<void> _writeChain = Future<void>.value();

  bool get isActive => _active;
  String? get currentPath => _path;

  /// Скільки секунд голосу дитини й персонажа реально потрапило в останній
  /// (щойно завершений) запис — діагностика для транскрипту квесту, щоб
  /// мовчання одного з джерел було видно одразу, а не лише при
  /// прослуховуванні файлу.
  double get lastMicSeconds => _micSamplesWritten / _targetRate;
  double get lastAgentSeconds => _agentSamplesWritten / _targetRate;

  /// Почати новий запис (новий файл). Якщо запис уже йде — нічого не робить.
  Future<void> start() async {
    if (_active) return;
    final sessionsDir = await RecordingsStore.sessionsDirectory();
    final ts = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );
    final path = '${sessionsDir.path}/quest_$ts.m4a';
    await _encoder.start(path, _targetRate);
    _path = path;
    _samplesWritten = 0;
    _micSamplesWritten = 0;
    _agentSamplesWritten = 0;
    _writeChain = Future<void>.value();
    _stopwatch
      ..reset()
      ..start();
    _active = true;
  }

  /// Дописати шматок голосу дитини (мікрофон) з його справжньою частотою
  /// дискретизації — підсилюється й ресемплюється до [_targetRate], якщо
  /// відрізняється.
  Future<void> writeMic(Uint8List pcm16, int sourceRate) => _enqueue(
    () => _writeChunk(_applyGain(pcm16, _micGain), sourceRate, mic: true),
  );

  /// Дописати шматок голосу персонажа.
  Future<void> writeAgent(Uint8List pcm16, int sourceRate) =>
      _enqueue(() => _writeChunk(pcm16, sourceRate, mic: false));

  Future<void> _enqueue(Future<void> Function() op) {
    final next = _writeChain.then((_) => op());
    _writeChain = next.catchError((_) {});
    return next;
  }

  Future<void> _writeChunk(
    Uint8List pcm16,
    int sourceRate, {
    required bool mic,
  }) async {
    if (!_active) return;
    await _padSilenceToNow();
    final resampled = sourceRate == _targetRate
        ? pcm16
        : _resample(pcm16, sourceRate, _targetRate);
    await _encoder.write(resampled);
    final n = resampled.length ~/ 2;
    _samplesWritten += n;
    if (mic) {
      _micSamplesWritten += n;
    } else {
      _agentSamplesWritten += n;
    }
  }

  /// Просте цифрове підсилення з захистом від кліпінгу (насичення на межах
  /// Int16, без переповнення).
  Uint8List _applyGain(Uint8List pcm16, double gain) {
    final samples = pcm16.length ~/ 2;
    if (samples == 0) return pcm16;
    final src = pcm16.buffer.asInt16List(pcm16.offsetInBytes, samples);
    final out = Int16List(samples);
    for (var i = 0; i < samples; i++) {
      out[i] = (src[i] * gain).round().clamp(-32768, 32767);
    }
    return out.buffer.asUint8List();
  }

  /// Заповнити тишею розрив між тим, скільки семплів реально записано, і
  /// тим, скільки мало б минути за годинником сесії — щоб паузи в розмові
  /// (очікування відповіді дитини, роздуми персонажа) лишались у записі.
  Future<void> _padSilenceToNow() async {
    final expected = (_stopwatch.elapsedMicroseconds / 1e6 * _targetRate)
        .round();
    final gap = expected - _samplesWritten;
    if (gap > 0) {
      await _encoder.write(Uint8List(gap * 2)); // PCM16 нулі = тиша
      _samplesWritten += gap;
    }
  }

  /// Лінійна інтерполяція — якості достатньо для архівного запису розмови,
  /// не для продакшн-обробки звуку.
  Uint8List _resample(Uint8List pcm16, int fromRate, int toRate) {
    final srcSamples = pcm16.length ~/ 2;
    if (srcSamples == 0) return pcm16;
    final data = pcm16.buffer.asInt16List(pcm16.offsetInBytes, srcSamples);
    final dstSamples = (srcSamples * toRate / fromRate).round();
    final out = Int16List(dstSamples);
    for (var i = 0; i < dstSamples; i++) {
      final srcPos = i * fromRate / toRate;
      final idx = srcPos.floor().clamp(0, srcSamples - 1);
      final frac = srcPos - idx;
      final s0 = data[idx];
      final s1 = data[(idx + 1).clamp(0, srcSamples - 1)];
      out[i] = (s0 + (s1 - s0) * frac).round();
    }
    return out.buffer.asUint8List();
  }

  /// Завершити й зберегти поточний запис на диск. Після цього готовий до
  /// нового [start].
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    _stopwatch.stop();
    await _writeChain;
    await _encoder.stop();
  }
}

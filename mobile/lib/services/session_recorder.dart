import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Автоматичний запис однієї спроби квесту (від почутого кодового слова до
/// перемоги/тайм-ауту/зупинки) в один моно WAV-файл на диску — для
/// подальшого прослуховування/діагностики. Мікрофон (голос дитини) і голос
/// персонажа пишуться в той самий файл у реальному хронологічному порядку;
/// оскільки [AudioPipeline] апаратно вимикає мікрофон, поки говорить
/// персонаж (напівдуплекс), напряму накладання немає — лише паузи, які
/// заповнюються тишею за годинником, щоб темп розмови в записі був
/// правдивим.
class SessionRecorder {
  static const _targetRate = 24000; // Hz, той самий, що й вихід Gemini/OpenAI

  RandomAccessFile? _raf;
  File? _file;
  int _samplesWritten = 0;
  final _stopwatch = Stopwatch();
  bool _active = false;
  Future<void> _writeChain = Future<void>.value();

  bool get isActive => _active;
  String? get currentPath => _file?.path;

  /// Почати новий запис (новий файл). Якщо запис уже йде — нічого не робить.
  Future<void> start() async {
    if (_active) return;
    final docs = await getApplicationDocumentsDirectory();
    final sessionsDir = Directory('${docs.path}/sessions');
    await sessionsDir.create(recursive: true);
    final ts = DateTime.now().toIso8601String().replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );
    final file = File('${sessionsDir.path}/quest_$ts.wav');
    final raf = await file.open(mode: FileMode.write);
    await raf.writeFrom(_wavHeader(0));
    _file = file;
    _raf = raf;
    _samplesWritten = 0;
    _writeChain = Future<void>.value();
    _stopwatch
      ..reset()
      ..start();
    _active = true;
  }

  /// Дописати шматок голосу дитини (мікрофон) з його справжньою частотою
  /// дискретизації — ресемплюється до [_targetRate], якщо відрізняється.
  Future<void> writeMic(Uint8List pcm16, int sourceRate) =>
      _enqueue(() => _writeChunk(pcm16, sourceRate));

  /// Дописати шматок голосу персонажа.
  Future<void> writeAgent(Uint8List pcm16, int sourceRate) =>
      _enqueue(() => _writeChunk(pcm16, sourceRate));

  Future<void> _enqueue(Future<void> Function() op) {
    final next = _writeChain.then((_) => op());
    _writeChain = next.catchError((_) {});
    return next;
  }

  Future<void> _writeChunk(Uint8List pcm16, int sourceRate) async {
    final raf = _raf;
    if (!_active || raf == null) return;
    await _padSilenceToNow(raf);
    final resampled = sourceRate == _targetRate
        ? pcm16
        : _resample(pcm16, sourceRate, _targetRate);
    await raf.writeFrom(resampled);
    _samplesWritten += resampled.length ~/ 2;
  }

  /// Заповнити тишею розрив між тим, скільки семплів реально записано, і
  /// тим, скільки мало б минути за годинником сесії — щоб паузи в розмові
  /// (очікування відповіді дитини, роздуми персонажа) лишались у записі.
  Future<void> _padSilenceToNow(RandomAccessFile raf) async {
    final expected = (_stopwatch.elapsedMicroseconds / 1e6 * _targetRate)
        .round();
    final gap = expected - _samplesWritten;
    if (gap > 0) {
      await raf.writeFrom(Uint8List(gap * 2)); // PCM16 нулі = тиша
      _samplesWritten += gap;
    }
  }

  /// Лінійна інтерполяція — якості достатньо для архівного запису розмови,
  /// не для продакшн-обробки звуку.
  Uint8List _resample(Uint8List pcm16, int fromRate, int toRate) {
    final srcSamples = pcm16.length ~/ 2;
    if (srcSamples == 0) return pcm16;
    final data = pcm16.buffer.asInt16List(
      pcm16.offsetInBytes,
      srcSamples,
    );
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

  /// Завершити й зберегти поточний запис на диск (дописує правильний
  /// розмір у WAV-заголовок). Після цього готовий до нового [start].
  Future<void> stop() async {
    if (!_active) return;
    _active = false;
    _stopwatch.stop();
    await _writeChain;
    final raf = _raf;
    _raf = null;
    if (raf == null) return;
    try {
      final dataLength = _samplesWritten * 2;
      await raf.setPosition(0);
      await raf.writeFrom(_wavHeader(dataLength));
    } finally {
      await raf.close();
    }
  }

  Uint8List _wavHeader(int dataLength) {
    const bitsPerSample = 16;
    const channels = 1;
    final byteRate = _targetRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final b = BytesBuilder();
    void str(String s) => b.add(s.codeUnits);
    void u32(int v) => b.add([
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ]);
    void u16(int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);

    str('RIFF');
    u32(36 + dataLength);
    str('WAVE');
    str('fmt ');
    u32(16);
    u16(1); // PCM
    u16(channels);
    u32(_targetRate);
    u32(byteRate);
    u16(blockAlign);
    u16(bitsPerSample);
    str('data');
    u32(dataLength);
    return b.toBytes();
  }
}

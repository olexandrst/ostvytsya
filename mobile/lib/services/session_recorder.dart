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
  int _micPeak = 0;
  String? _lastError;
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

  /// Найгучніший семпл мікрофону за сесію, 0..1. Відрізняє «мікрофон узагалі
  /// не писався» (секунди = 0) від «писався, але прийшла сама тиша»
  /// (секунди > 0, а пік ≈ 0) — це принципово різні несправності.
  double get lastMicPeak => _micPeak / 32767;

  /// Перша помилка запису за сесію (раніше будь-який виняток гасився мовчки
  /// і несправність була невидимою).
  String? get lastError => _lastError;

  /// Почати новий запис (новий файл). Якщо запис уже йде — нічого не робить.
  ///
  /// [baseName] — спільна основа імені сесії (див. newSessionBaseName у
  /// session_logger.dart): аудіо стає `<baseName>.m4a`, а текстовий журнал
  /// тієї самої сесії — `<baseName>.txt`, щоб їх легко було зіставити.
  ///
  /// Запис іде у спільну медіатеку пристрою (`Music/Оствиця`), щоб пережити
  /// видалення застосунку; якщо система застара для MediaStore — у теку
  /// застосунку, як раніше.
  Future<void> start(String baseName) async {
    if (_active) return;
    final legacyDir = await RecordingsStore.legacyDirectory();
    final name = '$baseName.m4a';
    final fallbackPath = '${legacyDir.path}/$name';
    final uri = await _encoder.start(name, fallbackPath, _targetRate);
    _path = uri ?? fallbackPath;
    _samplesWritten = 0;
    _micSamplesWritten = 0;
    _agentSamplesWritten = 0;
    _micPeak = 0;
    _lastError = null;
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

  /// Помилку запису НЕ гасимо мовчки (як було раніше) — запам'ятовуємо першу
  /// й показуємо в транскрипті квесту. Саме мовчазне гасіння приховувало те,
  /// що кожен мікрофонний шматок падав із винятком, а запис при цьому
  /// виглядав справним.
  Future<void> _enqueue(Future<void> Function() op) {
    final next = _writeChain.then((_) => op()).catchError((Object e) {
      _lastError ??= '$e';
    });
    _writeChain = next;
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

  /// Прочитати PCM16 із буфера БЕЗ вимоги до вирівнювання.
  ///
  /// ‼️ Навмисно НЕ `pcm16.buffer.asInt16List(pcm16.offsetInBytes, n)`: той
  /// виклик КИДАЄ ArgumentError, якщо зсув у буфері не кратний 2. А шматки
  /// мікрофону приходять із плагіна `record` через EventChannel як ВИГЛЯД
  /// (view) на спільний буфер повідомлення — із довільним зсувом, який
  /// цілком може бути непарним. Саме через це голос дитини мовчки зникав
  /// із запису: підсилення й ресемплінг — ЄДИНИЙ шлях, яким іде мікрофон
  /// (16 кГц ≠ 24 кГц), і обидва падали на цьому виклику, а виняток гасився
  /// в _enqueue. Голос персонажа (24 кГц = цільова частота) обминав і
  /// підсилення, і ресемплінг, тож писався справно — звідси й асиметрія
  /// «персонажа чути, дитину ні».
  ///
  /// ByteData.getInt16 читає побайтово з явним порядком байтів, тож працює
  /// за будь-якого зсуву.
  Int16List _readSamples(Uint8List pcm16) {
    final n = pcm16.length ~/ 2;
    final view = ByteData.sublistView(pcm16);
    final out = Int16List(n);
    for (var i = 0; i < n; i++) {
      out[i] = view.getInt16(i * 2, Endian.little);
    }
    return out;
  }

  /// Зворотне перетворення — так само без припущень про вирівнювання й із
  /// явним порядком байтів (little-endian, як і весь PCM16 у цьому проєкті).
  Uint8List _writeSamples(Int16List samples) {
    final out = Uint8List(samples.length * 2);
    final view = ByteData.sublistView(out);
    for (var i = 0; i < samples.length; i++) {
      view.setInt16(i * 2, samples[i], Endian.little);
    }
    return out;
  }

  /// Просте цифрове підсилення з захистом від кліпінгу (насичення на межах
  /// Int16, без переповнення). Заразом запам'ятовує пік сигналу — для
  /// діагностики «мікрофон пише саму тишу».
  Uint8List _applyGain(Uint8List pcm16, double gain) {
    final samples = _readSamples(pcm16);
    if (samples.isEmpty) return pcm16;
    for (var i = 0; i < samples.length; i++) {
      final raw = samples[i];
      final peak = raw < 0 ? -raw : raw;
      if (peak > _micPeak) _micPeak = peak;
      samples[i] = (raw * gain).round().clamp(-32768, 32767);
    }
    return _writeSamples(samples);
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
    final data = _readSamples(pcm16);
    final srcSamples = data.length;
    if (srcSamples == 0) return pcm16;
    final dstSamples = (srcSamples * toRate / fromRate).round();
    final out = Int16List(dstSamples);
    for (var i = 0; i < dstSamples; i++) {
      final srcPos = i * fromRate / toRate;
      final idx = srcPos.floor().clamp(0, srcSamples - 1);
      final frac = srcPos - idx;
      final s0 = data[idx];
      final s1 = data[(idx + 1).clamp(0, srcSamples - 1)];
      out[i] = (s0 + (s1 - s0) * frac).round().clamp(-32768, 32767);
    }
    return _writeSamples(out);
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
